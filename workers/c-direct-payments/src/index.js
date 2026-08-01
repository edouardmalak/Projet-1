// =====================================================================
// C-DIRECT — Worker "c-direct-payments"
//
// Onboarding Stripe Connect : carte de garantie côté pharmacie (SetupIntent
// sur le compte PLATEFORME, sans on_behalf_of), compte connecté Express
// côté pharmacien. AUCUNE charge, capture, ni annulation ici — ça viendra
// dans une passe dédiée une fois l'onboarding testé de bout en bout.
//
// Secrets (jamais dans ce fichier, jamais dans git — `wrangler secret put`) :
//   STRIPE_SECRET_KEY, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Écrit en suivant la documentation Stripe officielle (juillet 2026) :
//   - Comptes connectés : `controller` (pas `type`, déprécié) —
//     https://docs.stripe.com/api/accounts/create
//   - Account Links : type=account_onboarding, refresh_url doit être un
//     endpoint VIVANT (les liens expirent en ~5 min, usage unique) —
//     https://docs.stripe.com/api/account_links/create
//   - Carte clonée par charge directe plus tard, jamais on_behalf_of ici —
//     https://docs.stripe.com/connect/direct-charges-multiple-accounts
// =====================================================================

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') return corsPreflight();

    try {
      if (url.pathname === '/health')
        return json({
          ok: true,
          worker: 'c-direct-payments',
          stripe_key_configured: Boolean(env.STRIPE_SECRET_KEY),
          supabase_configured: Boolean(env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY),
        });

      if (request.method === 'POST' && url.pathname === '/pharmacien/onboarding-start')
        return await routeOnboardingStart(request, env);

      if (request.method === 'GET' && url.pathname === '/pharmacien/onboarding-refresh')
        return await routeOnboardingRefresh(request, env);

      if (request.method === 'POST' && url.pathname === '/pharmacie/setup-intent')
        return await routeSetupIntent(request, env);

      if (request.method === 'POST' && url.pathname === '/pharmacie/setup-confirm')
        return await routeSetupConfirm(request, env);

      return json({ erreur: 'Route inconnue' }, 404);
    } catch (e) {
      console.error('Erreur worker:', e.stack || e.message);
      return json({ erreur: e.message || 'Erreur interne' }, e.status && e.status < 500 ? e.status : 500);
    }
  },
};

/* =====================================================================
   OUTILS HTTP (mêmes conventions que le Worker c-direct-sms)
===================================================================== */
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};
function corsPreflight() { return new Response(null, { status: 204, headers: CORS }); }
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS },
  });
}

/* =====================================================================
   SUPABASE — REST service_role (jamais le client, toujours le serveur)
===================================================================== */
function sbHeaders(env, extra = {}) {
  return {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    'Content-Type': 'application/json',
    ...extra,
  };
}
async function sbSelect(env, chemin) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${chemin}`, { headers: sbHeaders(env) });
  if (!r.ok) throw new Error(`Supabase SELECT ${chemin} → ${r.status}: ${await r.text()}`);
  return r.json();
}
async function sbUpsert(env, table, lignes, onConflict) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${table}?on_conflict=${onConflict}`, {
    method: 'POST',
    headers: sbHeaders(env, { Prefer: 'resolution=merge-duplicates,return=representation' }),
    body: JSON.stringify(lignes),
  });
  if (!r.ok) throw new Error(`Supabase UPSERT ${table} → ${r.status}: ${await r.text()}`);
  return r.json();
}

/* Vérifie le jeton Supabase envoyé par le site (Authorization: Bearer <access_token>)
   et retourne l'utilisateur authentifié. Ne fait JAMAIS confiance à un profil_id
   fourni par le client — toujours dérivé du jeton. */
async function utilisateurConnecte(request, env) {
  const auth = request.headers.get('Authorization') || '';
  const jeton = auth.replace(/^Bearer\s+/i, '');
  if (!jeton) { const e = new Error('Non connecté'); e.status = 401; throw e; }

  const r = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${jeton}` },
  });
  if (!r.ok) { const e = new Error('Session invalide'); e.status = 401; throw e; }
  const u = await r.json();
  if (!u?.id) { const e = new Error('Session invalide'); e.status = 401; throw e; }
  return u; // { id, email, ... }
}

/* =====================================================================
   STRIPE — appels REST directs (pas de SDK, compatible Workers)
===================================================================== */
function versParamsFormulaire(obj) {
  const params = new URLSearchParams();
  const marcher = (valeur, cle) => {
    if (valeur === undefined || valeur === null) return;
    if (Array.isArray(valeur)) { valeur.forEach((v, i) => marcher(v, `${cle}[${i}]`)); return; }
    if (typeof valeur === 'object') {
      for (const [k, v] of Object.entries(valeur)) marcher(v, cle ? `${cle}[${k}]` : k);
      return;
    }
    params.append(cle, String(valeur));
  };
  for (const [k, v] of Object.entries(obj)) marcher(v, k);
  return params;
}

async function stripeApi(env, method, chemin, corps, { idempotencyKey, compteConnecte } = {}) {
  const headers = { Authorization: 'Basic ' + btoa(`${env.STRIPE_SECRET_KEY}:`) };
  if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
  if (compteConnecte) headers['Stripe-Account'] = compteConnecte;

  let corpsEnvoye;
  if (corps) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    corpsEnvoye = versParamsFormulaire(corps).toString();
  }

  const r = await fetch(`https://api.stripe.com/v1/${chemin}`, { method, headers, body: corpsEnvoye });
  const data = await r.json();
  if (!r.ok) {
    const e = new Error(data?.error?.message || `Stripe ${chemin} → ${r.status}`);
    e.stripe = data?.error;
    e.status = r.status >= 500 ? 502 : 400;
    throw e;
  }
  return data;
}

/* =====================================================================
   PHARMACIEN — onboarding Connect Express
===================================================================== */
async function routeOnboardingStart(request, env) {
  const u = await utilisateurConnecte(request, env);
  const body = await request.json().catch(() => ({}));
  const returnUrl = body.return_url || 'https://c-direct.ca/profil.html?onboarding=retour';

  const [ligne] = await sbSelect(
    env,
    `stripe_comptes?profil_id=eq.${u.id}&select=stripe_account_id`
  );

  let compteId = ligne?.stripe_account_id;

  if (!compteId) {
    // Compte connecté Express créé via `controller` (pas le `type=express`
    // déprécié) : Stripe EXIGE alors explicitement que la PLATEFORME (pas le
    // compte connecté, pas Stripe) paie les frais Stripe et soit responsable
    // des soldes négatifs/rétrofacturations — confirmé par un vrai rejet API
    // (« your platform must collect fees and be liable for negative balances
    // or refunds and chargebacks »), pas une hypothèse. C'est l'inverse de ce
    // que la doc générique Connect pricing laissait supposer par défaut.
    // Conséquence à traiter dans la machine à états (phase suivante) :
    // application_fee_amount devra couvrir le fee Stripe EN PLUS des 39 $ de
    // C-Direct (sinon C-Direct perd ~3 $/quart), et C-Direct — pas Stripe —
    // encaisse le risque d'un solde négatif si un pharmacien connecté a une
    // rétrofacturation après avoir déjà été payé. Rien de tout ça ne change
    // ce que la pharmacie paie ou ce que le pharmacien reçoit — seulement la
    // plomberie interne des frais Stripe. À garder en tête pour la phase 2.
    const compte = await stripeApi(
      env,
      'POST',
      'accounts',
      {
        country: 'CA',
        email: u.email,
        controller: {
          stripe_dashboard: { type: 'express' },
          fees: { payer: 'application' },
          losses: { payments: 'application' },
        },
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
      },
      // Clé fraîche à chaque appel (pas déterministe sur u.id) : une clé
      // stable causait un blocage dès qu'un essai précédent avait échoué
      // avec des paramètres différents (Stripe refuse alors la réutilisation
      // — « Keys for idempotent requests can only be used with the same
      // parameters »). Ce n'est pas un risque de doublon : la vérification
      // juste au-dessus (`if (!compteId)`) est déjà ce qui empêche de créer
      // un second compte connecté pour le même utilisateur.
      { idempotencyKey: `${u.id}:create-express-account:${crypto.randomUUID()}` }
    );
    compteId = compte.id;

    await sbUpsert(
      env,
      'stripe_comptes',
      [{ profil_id: u.id, stripe_account_id: compteId, updated_at: new Date().toISOString() }],
      'profil_id'
    );
  }

  const lien = await creerLienOnboarding(env, compteId, returnUrl);
  return json({ url: lien.url, account: compteId });
}

/* refresh_url : Stripe redirige ICI si le lien a expiré (~5 min) ou déjà
   été visité — cet endpoint doit être VIVANT et générer un nouveau lien,
   jamais une page statique. */
async function routeOnboardingRefresh(request, env) {
  const url = new URL(request.url);
  const compteId = url.searchParams.get('account');
  const returnUrl = url.searchParams.get('return_url') || 'https://c-direct.ca/profil.html?onboarding=retour';
  if (!compteId) return json({ erreur: 'account manquant' }, 400);

  // Le compte doit exister dans notre table (pas de lien pour un ID inventé)
  const [ligne] = await sbSelect(
    env,
    `stripe_comptes?stripe_account_id=eq.${compteId}&select=stripe_account_id`
  );
  if (!ligne) return json({ erreur: 'Compte inconnu' }, 404);

  const lien = await creerLienOnboarding(env, compteId, returnUrl);
  return Response.redirect(lien.url, 302);
}

async function creerLienOnboarding(env, compteId, returnUrl) {
  const refreshUrl =
    `https://c-direct-payments.edouardmalak.workers.dev/pharmacien/onboarding-refresh` +
    `?account=${encodeURIComponent(compteId)}&return_url=${encodeURIComponent(returnUrl)}`;

  return stripeApi(env, 'POST', 'account_links', {
    account: compteId,
    type: 'account_onboarding',
    return_url: returnUrl,
    refresh_url: refreshUrl,
  });
}

/* =====================================================================
   PHARMACIE — carte "garantie de paiement" (SetupIntent, compte PLATEFORME)
===================================================================== */
async function routeSetupIntent(request, env) {
  const u = await utilisateurConnecte(request, env);

  const [ligne] = await sbSelect(
    env,
    `stripe_comptes?profil_id=eq.${u.id}&select=stripe_customer_id`
  );
  let customerId = ligne?.stripe_customer_id;

  if (!customerId) {
    // Customer PLATEFORME — jamais on_behalf_of ici (sinon le clonage vers
    // le compte connecté du pharmacien, plus tard, sera impossible).
    const customer = await stripeApi(
      env,
      'POST',
      'customers',
      { email: u.email, metadata: { profil_id: u.id } },
      { idempotencyKey: `${u.id}:create-platform-customer` }
    );
    customerId = customer.id;
    await sbUpsert(
      env,
      'stripe_comptes',
      [{ profil_id: u.id, stripe_customer_id: customerId, updated_at: new Date().toISOString() }],
      'profil_id'
    );
  }

  const setupIntent = await stripeApi(env, 'POST', 'setup_intents', {
    customer: customerId,
    'payment_method_types[]': 'card',
    usage: 'off_session',
    metadata: { profil_id: u.id },
  });

  return json({ client_secret: setupIntent.client_secret });
}

/* Vérification légère après confirmation côté client (Stripe.js) — ne réécrit
   rien de nouveau (le customer_id est déjà enregistré ; la carte est déjà
   attachée par Stripe au customer dès la confirmation réussie). */
async function routeSetupConfirm(request, env) {
  const u = await utilisateurConnecte(request, env);
  const body = await request.json().catch(() => ({}));
  if (!body.setup_intent_id) return json({ erreur: 'setup_intent_id manquant' }, 400);

  const si = await stripeApi(env, 'GET', `setup_intents/${body.setup_intent_id}`);
  const reussi = si.status === 'succeeded';
  return json({ ok: reussi, statut: si.status });
}
