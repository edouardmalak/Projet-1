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

      if (request.method === 'POST' && url.pathname === '/pharmacien/confirmer-paiement')
        return await routeConfirmerPaiement(request, env);

      // Déclenche manuellement le même cycle que le cron planifié (voir
      // `scheduled` plus bas) — utile pour tester sans attendre le
      // prochain passage. Réservé aux admins (vérifie profiles.role).
      if (request.method === 'POST' && url.pathname === '/admin/executer-cycle-garanties')
        return await routeAdminExecuterCycle(request, env);

      return json({ erreur: 'Route inconnue' }, 404);
    } catch (e) {
      console.error('Erreur worker:', e.stack || e.message);
      return json({ erreur: e.message || 'Erreur interne' }, e.status && e.status < 500 ? e.status : 500);
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
   - Autorisation créée une fois à T-24h ; PAS de relance multi-paliers
     (T-18h / carte de secours / SMS T-12h / escalade T-6h) — à construire
     séparément (tâche #19 restante).
   - Le palier "pending_locum_confirmation" (la pharmacie clique "je l'ai
     envoyé", délai +60 min) n'est PAS câblé côté UI pharmacie — seule la
     confirmation du PHARMACIEN (source de vérité unique, voir skill)
     est implémentée ici.
   - Le webhook account.updated n'existe pas encore : le statut
     charges_enabled/payouts_enabled est vérifié en direct (GET) à
     chaque tentative d'autorisation plutôt que mis en cache.
   - Palier "next business day 16:00" (pharmacies avec comptable) pas
     implémenté — tout le monde est sur le délai standard de 3h.
===================================================================== */

const FRAIS_CDIRECT_DOLLARS = 39;
const FRAIS_STRIPE_POURCENT = 0.029;
const FRAIS_STRIPE_FIXE_DOLLARS = 0.30;

// card_price = (locum_rate + cdirect_fee + 0.30) / (1 - 0.029) — voir skill
// c-direct-payments § Pricing. Le fee Stripe est payé par la PLATEFORME (pas
// le compte connecté) parce que controller.fees.payer='application' a été
// forcé à la création du compte Express (tâche #18) ; l'application_fee_amount
// doit donc couvrir le fee C-Direct ET le fee Stripe pour que le pharmacien
// reçoive exactement montant_locum et que C-Direct nette bien 39 $.
function calculerMontantCarte(montantLocum) {
  return (montantLocum + FRAIS_CDIRECT_DOLLARS + FRAIS_STRIPE_FIXE_DOLLARS) / (1 - FRAIS_STRIPE_POURCENT);
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

/* Phase A — crée l'autorisation carte pour une candidature dont le quart
   démarre bientôt. Clone la carte plateforme vers le compte connecté du
   pharmacien (jamais on_behalf_of, jamais réutilisée — un clone par
   quart, consommé par la charge : docs.stripe.com/connect/direct-charges-multiple-accounts),
   puis crée une PaymentIntent à capture manuelle EN CHARGE DIRECTE
   (Stripe-Account: compte connecté) — hors ligne (off_session: true),
   personne n'est présent à T-24h. */
async function autoriserCandidature(env, ligne) {
  const { candidature_id, pharmacien_id, pharmacie_id, montant_locum, tentative_precedente } = ligne;

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
      throw new Error(`Compte pharmacien pas encore actif (charges_enabled=${compte.charges_enabled}, payouts_enabled=${compte.payouts_enabled})`);
    }

    // Clone à usage unique de la carte plateforme vers le compte connecté.
    const clone = await stripeApi(
      env, 'POST', 'payment_methods',
      { customer: comptePharmacie.stripe_customer_id, payment_method: comptePharmacie.stripe_payment_method_id },
      { compteConnecte: comptePharmacien.stripe_account_id }
    );

    const montantCarte = calculerMontantCarte(montant_locum);
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
    });
    await journaliser(env, garantie.id, 'awaiting_authorization', 'authorized', `PI ${pi.id}, capture_before=${captureBeforeUnix}`);
    return { ok: true };
  } catch (e) {
    await majGarantie(env, garantie.id, {
      statut: 'authorization_failed',
      tentative_autorisation: (tentative_precedente || 0) + 1,
      derniere_erreur: String(e.message || e).slice(0, 500),
    });
    await journaliser(env, garantie.id, 'awaiting_authorization', 'authorization_failed', String(e.message || e).slice(0, 500));
    return { ok: false, erreur: e.message };
  }
}

async function capturerGarantie(env, ligne) {
  const { garantie_id, stripe_payment_intent_id, pharmacien_id } = ligne;
  try {
    const [compte] = await sbSelect(env, `stripe_comptes?profil_id=eq.${pharmacien_id}&select=stripe_account_id`);
    await stripeApi(
      env, 'POST', `payment_intents/${stripe_payment_intent_id}/capture`, {},
      { compteConnecte: compte.stripe_account_id }
    );
    await majGarantie(env, garantie_id, { statut: 'captured' });
    await journaliser(env, garantie_id, null, 'captured', 'Délai dépassé sans confirmation — capture automatique');
    return { ok: true };
  } catch (e) {
    await journaliser(env, garantie_id, null, 'captured', `ÉCHEC capture : ${String(e.message || e).slice(0, 500)}`);
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

  await majGarantie(env, garantie.id, { statut: 'confirmed_exact' });
  await journaliser(env, garantie.id, garantie.statut, 'confirmed_exact', 'Confirmé par le pharmacien : reçu, montant exact');
  return json({ ok: true, statut: 'confirmed_exact' });
}

async function routeAdminExecuterCycle(request, env) {
  const u = await utilisateurConnecte(request, env);
  if (!(await estAdmin(env, u.id))) { const e = new Error('Accès refusé'); e.status = 403; throw e; }
  const resultat = await executerCycleGaranties(env);
  return json(resultat);
}
