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

    if (request.method === 'OPTIONS') return corsPreflight(request);

    try {
      /* T8a (batch1) : webhook Stripe signé — pas de CORS (serveur→serveur),
         la signature EST l'authentification. Répond avant tout le reste. */
      if (request.method === 'POST' && url.pathname === '/stripe/webhook')
        return await routeStripeWebhook(request, env);

      const reponse = await (async () => {
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

      if (request.method === 'POST' && url.pathname === '/pharmacien/confirmer-paiement')
        return await routeConfirmerPaiement(request, env);

      if (request.method === 'POST' && url.pathname === '/pharmacie/jai-envoye')
        return await routePharmacieJaiEnvoye(request, env);

      // Déclenche manuellement le même cycle que le cron planifié (voir
      // `scheduled` plus bas) — utile pour tester sans attendre le
      // prochain passage. Réservé aux admins (vérifie profiles.role).
      if (request.method === 'POST' && url.pathname === '/admin/executer-cycle-garanties')
        return await routeAdminExecuterCycle(request, env);

      return json({ erreur: 'Route inconnue' }, 404);
      })();
      /* T8c (batch1) : origine validée posée sur la réponse finale */
      reponse.headers.set('Access-Control-Allow-Origin', origineAutorisee(request));
      return reponse;
    } catch (e) {
      console.error('Erreur worker:', e.stack || e.message);
      const reponse = json({ erreur: e.message || 'Erreur interne' }, e.status && e.status < 500 ? e.status : 500);
      reponse.headers.set('Access-Control-Allow-Origin', origineAutorisee(request));
      return reponse;
    }
  },

  // Cloudflare Cron Trigger (voir wrangler.toml [triggers]) — même cycle
  // que /admin/executer-cycle-garanties, lancé automatiquement. Ce Worker
  // n'auto-déploie PAS depuis GitHub (contrairement à Pages) : après tout
  // changement de code, `npx wrangler deploy` doit être relancé à la main.
  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      executerCycleGaranties(env).catch((e) => console.error('Cycle garanties (cron) :', e.stack || e.message))
    );
  },
};

/* =====================================================================
   OUTILS HTTP (mêmes conventions que le Worker c-direct-sms)
===================================================================== */
/* T8c (batch1) : même liste d'origines que c-direct-chat — ce Worker est
   le plus sensible des trois, plus de « * ». Les routes renvoient encore
   l'en-tête générique via json() ; fetch() le REMPLACE par l'origine
   validée avant de répondre (les Response construites ici ont des
   en-têtes modifiables). */
function origineOk(origine) {
  if (!origine) return false;
  try {
    const h = new URL(origine).hostname;
    return h === 'c-direct.ca' || h === 'www.c-direct.ca' ||
           h === 'cdirect.quebec' || h === 'www.cdirect.quebec' ||
           h === 'projet-1-1yi.pages.dev' || h.endsWith('.projet-1-1yi.pages.dev') ||
           h === 'localhost';
  } catch (e) { return false; }
}
function origineAutorisee(request) {
  const origine = request.headers.get('Origin');
  return origineOk(origine) ? origine : 'https://c-direct.ca';
}
const CORS = {
  'Access-Control-Allow-Origin': 'https://c-direct.ca',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};
function corsPreflight(request) {
  return new Response(null, { status: 204, headers: { ...CORS, 'Access-Control-Allow-Origin': origineAutorisee(request) } });
}
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
   T8a (batch1) — WEBHOOK STRIPE CONNECT (signé, idempotent)
   Vérification de signature selon https://docs.stripe.com/webhooks
   (en-tête Stripe-Signature : HMAC-SHA256 de "{t}.{corps brut}" avec
   STRIPE_WEBHOOK_SECRET, tolérance 5 min). Dédoublonnage par event.id
   dans public.stripe_evenements (sql/74) — Stripe peut livrer deux fois.
   Rôle VOLONTAIREMENT limité : mettre en cache account.updated dans
   stripe_comptes.stripe_account_statut (colonne prévue depuis sql/42,
   lue par le moteur d'auto-acceptation sql/70) et JOURNALISER les
   évènements payment_intent.*. La machine à états reste pilotée par le
   cron (inchangé, il sert de filet si un webhook se perd).
===================================================================== */
function egaliteConstante(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function verifierSignatureStripe(secret, enTete, corpsBrut) {
  if (!secret || !enTete) return false;
  let t = null; const v1 = [];
  for (const partie of enTete.split(',')) {
    const i = partie.indexOf('=');
    if (i === -1) continue;
    const cle = partie.slice(0, i).trim(), valeur = partie.slice(i + 1).trim();
    if (cle === 't') t = valeur;
    if (cle === 'v1') v1.push(valeur);
  }
  if (!t || !v1.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;   // anti-rejeu, 5 min
  const cle = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign('HMAC', cle, new TextEncoder().encode(`${t}.${corpsBrut}`));
  const hex = [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return v1.some((v) => egaliteConstante(v, hex));
}

/* Retourne true si l'évènement est NOUVEAU (inséré), false s'il a déjà
   été traité (doublon Stripe) — Prefer: ignore-duplicates renvoie alors
   une représentation vide. */
async function evenementNouveau(env, evenement) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/stripe_evenements?on_conflict=id`, {
    method: 'POST',
    headers: sbHeaders(env, { Prefer: 'resolution=ignore-duplicates,return=representation' }),
    body: JSON.stringify([{ id: evenement.id, type: evenement.type, compte: evenement.account || null }]),
  });
  if (!r.ok) throw new Error(`Supabase INSERT stripe_evenements → ${r.status}: ${await r.text()}`);
  const lignes = await r.json();
  return Array.isArray(lignes) && lignes.length > 0;
}

async function routeStripeWebhook(request, env) {
  const corpsBrut = await request.text();
  const signatureOk = await verifierSignatureStripe(
    env.STRIPE_WEBHOOK_SECRET, request.headers.get('Stripe-Signature'), corpsBrut
  );
  if (!signatureOk) return new Response('Signature invalide', { status: 400 });

  let evenement;
  try { evenement = JSON.parse(corpsBrut); } catch (e) { return new Response('JSON invalide', { status: 400 }); }
  if (!evenement?.id || !evenement?.type) return new Response('Évènement invalide', { status: 400 });

  if (!(await evenementNouveau(env, evenement))) {
    return new Response(JSON.stringify({ ok: true, doublon: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  if (evenement.type === 'account.updated' && evenement.account) {
    const compte = evenement.data?.object || {};
    await fetch(`${env.SUPABASE_URL}/rest/v1/stripe_comptes?stripe_account_id=eq.${encodeURIComponent(evenement.account)}`, {
      method: 'PATCH',
      headers: sbHeaders(env, { Prefer: 'return=minimal' }),
      body: JSON.stringify({
        stripe_account_statut: {
          charges_enabled: compte.charges_enabled === true,
          payouts_enabled: compte.payouts_enabled === true,
          requirements: compte.requirements || null,
          maj_webhook: new Date().toISOString(),
        },
        updated_at: new Date().toISOString(),
      }),
    });
  } else if (evenement.type && evenement.type.startsWith('payment_intent.')) {
    const pi = evenement.data?.object || {};
    const garantieId = pi.metadata?.garantie_id;
    if (garantieId) {
      await journaliser(env, garantieId, null, `webhook:${evenement.type}`,
        `PI ${pi.id || '?'} statut=${pi.status || '?'} (évènement ${evenement.id})`);
    }
  }
  /* Tout autre type : accepté et ignoré (200) — Stripe cesse de relivrer. */

  return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'Content-Type': 'application/json' } });
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

/* Vérification après confirmation côté client (Stripe.js). Le customer_id
   est déjà enregistré (routeSetupIntent) ; ici on récupère en plus l'ID de
   la carte elle-même (setup_intent.payment_method) et on le stocke — il
   faudra la CLONER vers le compte connecté du pharmacien à chaque quart
   (state machine, sql/43), donc il faut son ID précis, pas juste "une
   carte existe sur ce customer". On la met aussi en défaut du customer
   (hygiène : la prochaine carte ajoutée ne la remplace pas silencieusement). */
async function routeSetupConfirm(request, env) {
  const u = await utilisateurConnecte(request, env);
  const body = await request.json().catch(() => ({}));
  if (!body.setup_intent_id) return json({ erreur: 'setup_intent_id manquant' }, 400);

  const si = await stripeApi(env, 'GET', `setup_intents/${body.setup_intent_id}`);
  const reussi = si.status === 'succeeded';

  if (reussi && si.payment_method) {
    await sbUpsert(
      env,
      'stripe_comptes',
      [{ profil_id: u.id, stripe_payment_method_id: si.payment_method, updated_at: new Date().toISOString() }],
      'profil_id'
    );
    if (si.customer) {
      await stripeApi(env, 'POST', `customers/${si.customer}`, {
        invoice_settings: { default_payment_method: si.payment_method },
      });
    }
  }

  return json({ ok: reussi, statut: si.status });
}

/* =====================================================================
   GARANTIE DE PAIEMENT — machine à états (autorisation T-24h → capture
   ou annulation). Voir sql/43-garanties-paiement.sql pour le schéma et
   les RPC lister_* (elles font tout le filtrage SQL ; ce Worker ne fait
   qu'appeler Stripe et écrire le résultat).

   PÉRIMÈTRE DE CETTE PASSE (le reste est noté, pas construit en douce) :
   - Autorisation créée une fois à T-24h ; la relance multi-paliers
     (T-18h / SMS T-12h / escalade T-6h) a depuis été construite —
     sql/45, sql/46 et calculerProchainePhase() ci-dessous. Seule la
     « carte de secours » reste non construite (voir bloc ÉCHELLE DE
     RELANCE plus bas).
   - [T25 batch1 — commentaire périmé corrigé] Le palier
     "pending_locum_confirmation" ("j'ai envoyé", délai +60 min) EST
     câblé côté UI pharmacie : espace-pharmacie.html appelle
     POST /pharmacie/jai-envoye. La confirmation du PHARMACIEN reste la
     seule source de vérité (voir skill).
   - [T25 batch1] Le webhook Stripe existe désormais (/stripe/webhook,
     T8a) et met account.updated en cache dans stripe_comptes ; le GET
     direct à chaque tentative d'autorisation reste en place comme
     vérification de dernière minute — le statut
     chaque tentative d'autorisation plutôt que mis en cache.
   - Palier "next business day 16:00" (pharmacies avec comptable) pas
     implémenté — tout le monde est sur le délai standard de 3h.
===================================================================== */

// Valeur de repli SEULEMENT (voir fraisCdirect ci-dessous) : le vrai
// montant vit en base, dans parametres_plateforme, réglable par l'admin
// (sql/82). Cette constante ne sert que si la table est injoignable.
const FRAIS_CDIRECT_DOLLARS = 39;
const FRAIS_STRIPE_POURCENT = 0.029;
const FRAIS_STRIPE_FIXE_DOLLARS = 0.30;

/* Frais C-Direct en vigueur, lus en base à chaque autorisation (sql/82).
   Réglables depuis Administration → « Frais de plateforme » — mis à 0 $
   pendant la phase de test. En cas d'échec de lecture on retombe sur la
   constante plutôt que de facturer 0 $ par accident. */
async function fraisCdirect(env) {
  try {
    const [p] = await sbSelect(env, 'parametres_plateforme?id=eq.1&select=frais_cdirect_dollars');
    const v = Number(p?.frais_cdirect_dollars);
    return Number.isFinite(v) && v >= 0 ? v : FRAIS_CDIRECT_DOLLARS;
  } catch (e) {
    return FRAIS_CDIRECT_DOLLARS;
  }
}

// card_price = (locum_rate + cdirect_fee + 0.30) / (1 - 0.029) — voir skill
// c-direct-payments § Pricing. Le fee Stripe est payé par la PLATEFORME (pas
// le compte connecté) parce que controller.fees.payer='application' a été
// forcé à la création du compte Express (tâche #18) ; l'application_fee_amount
// doit donc couvrir le fee C-Direct ET le fee Stripe pour que le pharmacien
// reçoive exactement montant_locum et que C-Direct nette bien ses frais.
function calculerMontantCarte(montantLocum, frais = FRAIS_CDIRECT_DOLLARS) {
  return (montantLocum + frais + FRAIS_STRIPE_FIXE_DOLLARS) / (1 - FRAIS_STRIPE_POURCENT);
}

async function estAdmin(env, profilId) {
  const [ligne] = await sbSelect(env, `profiles?id=eq.${profilId}&select=role`);
  return ligne?.role === 'admin';
}

async function journaliser(env, garantieId, ancienStatut, nouveauStatut, note) {
  await fetch(`${env.SUPABASE_URL}/rest/v1/garanties_paiement_journal`, {
    method: 'POST',
    headers: sbHeaders(env),
    body: JSON.stringify([{ garantie_id: garantieId, ancien_statut: ancienStatut, nouveau_statut: nouveauStatut, note }]),
  });
}

async function majGarantie(env, id, champs) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/garanties_paiement?id=eq.${id}`, {
    method: 'PATCH',
    headers: sbHeaders(env, { Prefer: 'return=minimal' }),
    body: JSON.stringify({ ...champs, updated_at: new Date().toISOString() }),
  });
  if (!r.ok) throw new Error(`Supabase PATCH garanties_paiement → ${r.status}: ${await r.text()}`);
}

/* =====================================================================
   ÉCHELLE DE RELANCE (tâche #21) — T-24h (1re tentative, gérée par
   lister_candidatures_a_autoriser) → retry T-18h → SMS T-12h →
   escalade T-6h → authorization_failed. Voir sql/46-relance-paliers.sql.

   Palier « carte de secours » (entre T-18h et T-12h dans le skill)
   PAS construit : stripe_comptes n'a qu'une seule stripe_payment_method_id
   par pharmacie, aucune notion de deuxième carte n'existe encore côté
   DB/UI. Noté ici plutôt que silencieusement omis — à construire si une
   pharmacie a effectivement besoin d'une carte de secours en pratique.
===================================================================== */
function calculerProchainePhase(debutQuartIso) {
  const maintenant = Date.now();
  const debut = new Date(debutQuartIso).getTime();
  const heuresRestantes = (debut - maintenant) / 3600000;

  if (heuresRestantes > 18) {
    return { palier: 'T-18h', prochaineTentative: new Date(debut - 18 * 3600000), sms: false };
  }
  if (heuresRestantes > 12) {
    return { palier: 'T-12h-sms', prochaineTentative: new Date(debut - 12 * 3600000), sms: true };
  }
  if (heuresRestantes > 6) {
    return { palier: 'T-6h-escalade', prochaineTentative: new Date(debut - 6 * 3600000), sms: true };
  }
  // Sous les 6h (ou quart déjà commencé) : plus de paliers programmés à
  // l'avance — on retente à chaque cycle (15 min) jusqu'au plafond de 5
  // tentatives, mais on ne renvoie PAS de 2e SMS à chaque essai (le SMS
  // du palier T-6h-escalade a déjà été envoyé une fois en y entrant).
  return { palier: 'T-6h-escalade', prochaineTentative: new Date(maintenant + 15 * 60000), sms: false };
}

/* Insertion directe dans sms_queue (jamais d'appel Twilio depuis ce
   Worker — c-direct-sms vide la file chaque minute). envoyer_apres=now()
   court-circuite délibérément les heures de silence : ceci est une
   alerte transactionnelle sur un problème de paiement pour un quart
   imminent, pas une diffusion — même traitement que les confirmations
   pharmacie existantes (voir commentaire dans c-direct-sms/src/index.js
   « Confirmations pharmacie et rappel_veille : non concernés »).
   Échec d'envoi avalé + journalisé : ne doit jamais faire échouer le
   cycle de garanties lui-même. */
async function alerterPharmacieCarte(env, { pharmacie_id, corps }) {
  try {
    const [pharmacie] = await sbSelect(env, `profiles?id=eq.${pharmacie_id}&select=telephone,nom_pharmacie`);
    if (!pharmacie?.telephone) return { ok: false, raison: 'Pharmacie sans numéro de téléphone enregistré' };
    const r = await fetch(`${env.SUPABASE_URL}/rest/v1/sms_queue`, {
      method: 'POST',
      headers: sbHeaders(env, { Prefer: 'return=minimal' }),
      body: JSON.stringify([{
        profile_id: pharmacie_id,
        pharmacie_id,
        to_number: pharmacie.telephone,
        type: 'garantie_paiement_echec',
        corps,
        envoyer_apres: new Date().toISOString(),
      }]),
    });
    if (!r.ok) return { ok: false, raison: `Supabase INSERT sms_queue → ${r.status}: ${await r.text()}` };
    return { ok: true };
  } catch (e) {
    return { ok: false, raison: String(e.message || e) };
  }
}

/* Phase A — crée l'autorisation carte pour une candidature dont le quart
   démarre bientôt. Clone la carte plateforme vers le compte connecté du
   pharmacien (jamais on_behalf_of, jamais réutilisée — un clone par
   quart, consommé par la charge : docs.stripe.com/connect/direct-charges-multiple-accounts),
   puis crée une PaymentIntent à capture manuelle EN CHARGE DIRECTE
   (Stripe-Account: compte connecté) — hors ligne (off_session: true),
   personne n'est présent à T-24h. */
async function autoriserCandidature(env, ligne) {
  const {
    candidature_id, pharmacien_id, pharmacie_id, montant_locum, tentative_precedente,
    debut_quart, numero_reference, palier_precedent,
  } = ligne;

  // Upsert (pas un simple insert) : candidature_id est UNIQUE, et depuis
  // sql/45 cette fonction peut être appelée en RETENTATIVE sur une ligne
  // qui existe déjà (statut='authorization_failed') — un insert planterait
  // sur la contrainte unique. on_conflict réutilise la même ligne.
  const [garantie] = await fetch(`${env.SUPABASE_URL}/rest/v1/garanties_paiement?on_conflict=candidature_id`, {
    method: 'POST',
    headers: sbHeaders(env, { Prefer: 'resolution=merge-duplicates,return=representation' }),
    body: JSON.stringify([{
      candidature_id,
      statut: 'awaiting_authorization',
      montant_locum_cents: Math.round(montant_locum * 100),
    }]),
  }).then((r) => r.json());

  try {
    const [comptePharmacien] = await sbSelect(env, `stripe_comptes?profil_id=eq.${pharmacien_id}&select=stripe_account_id,stripe_account_statut`);
    const [comptePharmacie] = await sbSelect(env, `stripe_comptes?profil_id=eq.${pharmacie_id}&select=stripe_customer_id,stripe_payment_method_id`);

    if (!comptePharmacien?.stripe_account_id) {
      throw new Error('Le pharmacien n’a pas encore configuré ses paiements (onboarding Stripe non fait)');
    }
    if (!comptePharmacie?.stripe_customer_id || !comptePharmacie?.stripe_payment_method_id) {
      throw new Error('La pharmacie n’a pas encore enregistré de carte de garantie');
    }

    // Gate T-24h sur charges_enabled && payouts_enabled (skill : « Defer
    // Stripe onboarding... gate the T-24h authorization on charges_enabled
    // && payouts_enabled »). Vérifié en direct — pas encore de cache webhook.
    const compte = await stripeApi(env, 'GET', `accounts/${comptePharmacien.stripe_account_id}`);
    if (!compte.charges_enabled || !compte.payouts_enabled) {
      // Détail temporaire de debug (tâche #20) : `requirements` explique
      // PRÉCISÉMENT ce qui bloque payouts_enabled (ex. external_account
      // manquant) au lieu de juste constater qu'il est false — sans ça on
      // ne fait que deviner à chaque tentative. À retirer une fois le
      // premier cycle bout-en-bout confirmé.
      const req = compte.requirements || {};
      const detail = [
        req.disabled_reason ? `disabled_reason=${req.disabled_reason}` : null,
        req.currently_due?.length ? `currently_due=${req.currently_due.join(',')}` : null,
        req.past_due?.length ? `past_due=${req.past_due.join(',')}` : null,
        req.eventually_due?.length ? `eventually_due=${req.eventually_due.join(',')}` : null,
      ].filter(Boolean).join(' | ');
      throw new Error(`Compte pharmacien pas encore actif (charges_enabled=${compte.charges_enabled}, payouts_enabled=${compte.payouts_enabled})${detail ? ' — ' + detail : ''}`);
    }

    // Clone à usage unique de la carte plateforme vers le compte connecté.
    const clone = await stripeApi(
      env, 'POST', 'payment_methods',
      { customer: comptePharmacie.stripe_customer_id, payment_method: comptePharmacie.stripe_payment_method_id },
      { compteConnecte: comptePharmacien.stripe_account_id }
    );

    const montantCarte = calculerMontantCarte(montant_locum, await fraisCdirect(env));
    const montantCarteCents = Math.round(montantCarte * 100);
    const montantLocumCents = Math.round(montant_locum * 100);
    const fraisApplicationCents = montantCarteCents - montantLocumCents;

    const pi = await stripeApi(
      env, 'POST', 'payment_intents',
      {
        amount: montantCarteCents,
        currency: 'cad',
        payment_method: clone.id,
        confirm: true,
        off_session: true,
        capture_method: 'manual',
        application_fee_amount: fraisApplicationCents,
        'expand[]': 'latest_charge',
        metadata: { candidature_id, garantie_id: garantie.id },
      },
      { compteConnecte: comptePharmacien.stripe_account_id, idempotencyKey: `${garantie.id}:autoriser` }
    );

    if (pi.status !== 'requires_capture') {
      throw new Error(`Statut inattendu après autorisation : ${pi.status} (${pi.last_payment_error?.message || 'sans détail'})`);
    }

    const captureBeforeUnix = pi.latest_charge?.payment_method_details?.card?.capture_before;

    await majGarantie(env, garantie.id, {
      statut: 'authorized',
      stripe_payment_intent_id: pi.id,
      montant_carte_cents: montantCarteCents,
      capture_before: captureBeforeUnix ? new Date(captureBeforeUnix * 1000).toISOString() : null,
      tentative_autorisation: (tentative_precedente || 0) + 1,
      derniere_erreur: null,
      palier: null,
      prochaine_tentative: null,
    });
    await journaliser(env, garantie.id, 'awaiting_authorization', 'authorized', `PI ${pi.id}, capture_before=${captureBeforeUnix}`);
    return { ok: true };
  } catch (e) {
    const erreurTexte = String(e.message || e).slice(0, 500);
    const phase = calculerProchainePhase(debut_quart);
    const changeDePalier = phase.palier !== palier_precedent;

    let alerte = null;
    if (phase.sms && changeDePalier) {
      const urgent = phase.palier === 'T-6h-escalade';
      const dateAffichee = new Date(debut_quart).toLocaleDateString('fr-CA', { timeZone: 'America/Montreal' });
      const corps = urgent
        ? `C-Direct URGENT : la garantie de paiement du quart ${numero_reference || ''} (${dateAffichee}) est toujours en echec a 6h du debut. Corrigez votre carte de garantie immediatement : https://c-direct.ca/profil.html`
        : `C-Direct : la carte de garantie pour le quart ${numero_reference || ''} (${dateAffichee}) n'a pas pu etre autorisee. Verifiez/mettez a jour votre carte avant le debut du quart : https://c-direct.ca/profil.html`;
      alerte = await alerterPharmacieCarte(env, { pharmacie_id, corps });
    }

    await majGarantie(env, garantie.id, {
      statut: 'authorization_failed',
      tentative_autorisation: (tentative_precedente || 0) + 1,
      derniere_erreur: erreurTexte,
      palier: phase.palier,
      prochaine_tentative: phase.prochaineTentative.toISOString(),
    });
    await journaliser(
      env, garantie.id, 'awaiting_authorization', 'authorization_failed',
      `${erreurTexte} — palier=${phase.palier}, prochaine_tentative=${phase.prochaineTentative.toISOString()}` +
        (alerte ? `, sms_pharmacie=${alerte.ok ? 'envoyé' : 'échec:' + alerte.raison}` : '')
    );
    return { ok: false, erreur: e.message, palier: phase.palier };
  }
}

async function capturerGarantie(env, ligne) {
  const { garantie_id, stripe_payment_intent_id, pharmacien_id } = ligne;
  /* sql/83 : lister_garanties_a_capturer renvoie désormais le statut de
     départ. Avant, la capture était journalisée avec ancien_statut = null,
     et toute concaténation « ancien -> nouveau » valait NULL : la ligne
     existait mais restait invisible dans les relevés, précisément dans la
     table qui sert de preuve en cas de contestation de carte. Repli sur
     'authorized' si la migration n'est pas encore passée. */
  const statutDepart = ligne.statut || 'authorized';
  try {
    const [compte] = await sbSelect(env, `stripe_comptes?profil_id=eq.${pharmacien_id}&select=stripe_account_id`);
    await stripeApi(
      env, 'POST', `payment_intents/${stripe_payment_intent_id}/capture`, {},
      { compteConnecte: compte.stripe_account_id }
    );
    await majGarantie(env, garantie_id, { statut: 'captured' });
    await journaliser(env, garantie_id, statutDepart, 'captured', 'Délai dépassé sans confirmation — capture automatique');
    return { ok: true };
  } catch (e) {
    /* T8b (batch1) : avant, l'échec n'était QUE journalisé — la ligne
       restait dans lister_garanties_a_capturer et était retentée en
       silence toutes les 15 min, sans que personne ne le sache. Désormais :
       statut → capture_failed (état terminal distinct, sql/74 — la RPC ne
       resélectionne plus la ligne), SMS à la pharmacie (même canal que
       l'échec d'autorisation) et courriel admin (même mécanisme Web3Forms
       que cdAlerteAdmin côté client). Une garantie en capture_failed exige
       une intervention humaine : c'est un paiement dû non sécurisé. */
    const erreurTexte = String(e.message || e).slice(0, 500);
    await majGarantie(env, garantie_id, { statut: 'capture_failed', derniere_erreur: erreurTexte });
    await journaliser(env, garantie_id, statutDepart, 'capture_failed', `ÉCHEC capture : ${erreurTexte}`);

    let pharmacieId = null, reference = '';
    try {
      const [detail] = await sbSelect(
        env,
        `garanties_paiement?id=eq.${garantie_id}&select=candidature_id,candidatures(contrat_id,contrats(pharmacie_id,numero_reference))`
      );
      pharmacieId = detail?.candidatures?.contrats?.pharmacie_id || null;
      reference = detail?.candidatures?.contrats?.numero_reference || '';
    } catch (e2) { /* best-effort — l'alerte admin part quand même */ }

    if (pharmacieId) {
      await alerterPharmacieCarte(env, {
        pharmacie_id: pharmacieId,
        corps: `C-Direct URGENT : le prelevement de la garantie du quart ${reference} a echoue (carte refusee ou autorisation expiree). Le paiement du pharmacien n'est PAS securise. Contactez-nous ou reglez par Interac sans delai : https://c-direct.ca/espace-pharmacie.html`,
      });
    }
    try {
      await fetch('https://api.web3forms.com/submit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8', Accept: 'application/json' },
        body: JSON.stringify({
          access_key: '6d62e4bb-5cdd-42e9-8c64-5e9a9cf465eb',
          from_name: 'C-Direct — Worker paiements',
          subject: '[C-Direct] ECHEC DE CAPTURE — intervention requise',
          'Garantie': garantie_id,
          'Contrat': reference || '(inconnu)',
          'Erreur Stripe': erreurTexte,
          'À faire': 'Vérifier la garantie dans Stripe et relancer le paiement (admin.html → garanties).',
        }),
      });
    } catch (e3) { /* jamais bloquant */ }
    return { ok: false, erreur: e.message };
  }
}

/* Le cycle complet — appelé par le cron ET par /admin/executer-cycle-garanties.
   Trois phases indépendantes ; une erreur sur une ligne n'interrompt pas
   les autres (chaque helper avale ses propres erreurs et les journalise). */
async function executerCycleGaranties(env) {
  const resultat = { autorisations: [], echeances_fixees: 0, captures: [] };

  const candidatsDus = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/lister_candidatures_a_autoriser`, {
    method: 'POST', headers: sbHeaders(env), body: JSON.stringify({}),
  }).then((r) => r.json());

  for (const ligne of Array.isArray(candidatsDus) ? candidatsDus : []) {
    resultat.autorisations.push({ candidature_id: ligne.candidature_id, ...(await autoriserCandidature(env, ligne)) });
  }

  const echeancesAFixer = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/lister_echeances_a_fixer`, {
    method: 'POST', headers: sbHeaders(env), body: JSON.stringify({}),
  }).then((r) => r.json());

  for (const ligne of Array.isArray(echeancesAFixer) ? echeancesAFixer : []) {
    const echeance = new Date(new Date(ligne.date_envoi).getTime() + 3 * 3600 * 1000).toISOString();
    await majGarantie(env, ligne.garantie_id, { echeance_confirmation: echeance });
    resultat.echeances_fixees++;
  }

  const aCapturer = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/lister_garanties_a_capturer`, {
    method: 'POST', headers: sbHeaders(env), body: JSON.stringify({}),
  }).then((r) => r.json());

  for (const ligne of Array.isArray(aCapturer) ? aCapturer : []) {
    resultat.captures.push({ garantie_id: ligne.garantie_id, ...(await capturerGarantie(env, ligne)) });
  }

  return resultat;
}

/* Le PHARMACIEN confirme avoir reçu son paiement (Interac/chèque hors
   Stripe) — SEULE source de vérité (skill : « the locum is the only
   source of truth »). montant_exact=true → on ANNULE l'autorisation
   (garantie plus nécessaire, 0 $ prélevé). montant_exact=false → on
   flague l'écart SANS annuler (la garantie doit rester active). */
async function routeConfirmerPaiement(request, env) {
  const u = await utilisateurConnecte(request, env);
  const body = await request.json().catch(() => ({}));
  const { candidature_id, montant_exact } = body;
  if (!candidature_id || typeof montant_exact !== 'boolean')
    return json({ erreur: 'candidature_id et montant_exact (booléen) requis' }, 400);

  const [candidature] = await sbSelect(env, `candidatures?id=eq.${candidature_id}&select=pharmacien_id`);
  if (!candidature) return json({ erreur: 'Candidature introuvable' }, 404);
  if (candidature.pharmacien_id !== u.id) {
    const e = new Error('Seul le pharmacien de ce mandat peut confirmer son paiement'); e.status = 403; throw e;
  }

  const [garantie] = await sbSelect(env, `garanties_paiement?candidature_id=eq.${candidature_id}&select=*`);
  if (!garantie) return json({ erreur: 'Aucune garantie de paiement pour ce mandat' }, 404);
  if (!['authorized', 'pending_locum_confirmation', 'amount_mismatch'].includes(garantie.statut)) {
    return json({ erreur: `Garantie non confirmable dans son état actuel (${garantie.statut})` }, 409);
  }

  if (!montant_exact) {
    await majGarantie(env, garantie.id, { statut: 'amount_mismatch' });
    await journaliser(env, garantie.id, garantie.statut, 'amount_mismatch', 'Signalé par le pharmacien — garantie NON annulée');
    return json({ ok: true, statut: 'amount_mismatch' });
  }

  const [compte] = await sbSelect(env, `stripe_comptes?profil_id=eq.${u.id}&select=stripe_account_id`);
  try {
    await stripeApi(
      env, 'POST', `payment_intents/${garantie.stripe_payment_intent_id}/cancel`,
      { cancellation_reason: 'requested_by_customer' },
      { compteConnecte: compte.stripe_account_id }
    );
  } catch (e) {
    // « Returns an error if the PaymentIntent is already canceled or isn't
    // in a cancelable state » — traité comme un succès terminal (journalisé),
    // pas une erreur à remonter à l'utilisateur (docs.stripe.com/api/payment_intents/cancel).
    await journaliser(env, garantie.id, garantie.statut, 'confirmed_exact', `Annulation Stripe : ${e.message}`);
  }

  /* sql/85 — confirme_par est désormais EXIGÉ par la base pour atteindre
     confirmed_exact, et doit être le pharmacien du mandat. C'est ce qui
     rend impossible, au niveau de la base, qu'une pharmacie libère sa
     propre garantie. u.id est déjà vérifié égal à candidature.pharmacien_id
     plus haut dans cette route. */
  await majGarantie(env, garantie.id, { statut: 'confirmed_exact', confirme_par: u.id });
  await journaliser(env, garantie.id, garantie.statut, 'confirmed_exact', 'Confirmé par le pharmacien : reçu, montant exact');
  return json({ ok: true, statut: 'confirmed_exact' });
}

/* La PHARMACIE déclare avoir envoyé le paiement hors Stripe (Interac ou
   chèque, après un quart complété). C'est une réclamation NON vérifiée
   (skill : « the locum is the only source of truth ») — ça ne libère
   JAMAIS la garantie soi-même. Ça fait deux choses, rien de plus :
   1) statut → pending_locum_confirmation (affiché différemment côté
      pharmacien, qui voit alors qu'une confirmation est attendue) ;
   2) échéance += 60 min à partir de maintenant (ou de l'échéance
      existante si elle est déjà plus tard), pour laisser au pharmacien
      le temps de confirmer avant toute capture automatique.
   Idempotent : un second clic sur une garantie déjà en
   pending_locum_confirmation ne repousse PAS l'échéance à nouveau
   (sinon un clic répété pourrait repousser indéfiniment la capture de
   sécurité — jamais l'intention du délai de grâce). */
async function routePharmacieJaiEnvoye(request, env) {
  const u = await utilisateurConnecte(request, env);
  const body = await request.json().catch(() => ({}));
  const { candidature_id } = body;
  if (!candidature_id) return json({ erreur: 'candidature_id requis' }, 400);

  const [candidature] = await sbSelect(env, `candidatures?id=eq.${candidature_id}&select=contrat_id`);
  if (!candidature) return json({ erreur: 'Candidature introuvable' }, 404);
  const [contrat] = await sbSelect(env, `contrats?id=eq.${candidature.contrat_id}&select=pharmacie_id`);
  if (!contrat || contrat.pharmacie_id !== u.id) {
    const e = new Error('Seule la pharmacie de ce mandat peut déclarer un envoi de paiement'); e.status = 403; throw e;
  }

  const [garantie] = await sbSelect(env, `garanties_paiement?candidature_id=eq.${candidature_id}&select=*`);
  if (!garantie) return json({ erreur: 'Aucune garantie de paiement pour ce mandat' }, 404);

  if (garantie.statut === 'pending_locum_confirmation') {
    return json({ ok: true, statut: garantie.statut, deja_declare: true });
  }
  if (garantie.statut !== 'authorized') {
    return json({ erreur: `Rien à déclarer dans l'état actuel de la garantie (${garantie.statut})` }, 409);
  }

  const base = garantie.echeance_confirmation && new Date(garantie.echeance_confirmation) > new Date()
    ? new Date(garantie.echeance_confirmation)
    : new Date();
  const nouvelleEcheance = new Date(base.getTime() + 60 * 60000);

  await majGarantie(env, garantie.id, {
    statut: 'pending_locum_confirmation',
    echeance_confirmation: nouvelleEcheance.toISOString(),
  });
  await journaliser(
    env, garantie.id, garantie.statut, 'pending_locum_confirmation',
    `Déclaré par la pharmacie ("j'ai envoyé") — échéance repoussée à ${nouvelleEcheance.toISOString()}`
  );
  return json({ ok: true, statut: 'pending_locum_confirmation', echeance_confirmation: nouvelleEcheance.toISOString() });
}

async function routeAdminExecuterCycle(request, env) {
  const u = await utilisateurConnecte(request, env);
  if (!(await estAdmin(env, u.id))) { const e = new Error('Accès refusé'); e.status = 403; throw e; }
  const resultat = await executerCycleGaranties(env);
  return json(resultat);
}
