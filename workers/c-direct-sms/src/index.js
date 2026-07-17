// =====================================================================
// C-DIRECT · PHASE 4 — Worker "c-direct-sms"
// Supabase Database Webhooks → ce Worker → Twilio (REST, sans SDK).
// AUCUN secret dans ce fichier : tout vient de `wrangler secret put`.
//   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER,
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, WEBHOOK_SECRET
// =====================================================================

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // CORS : le bouton test de la console admin appelle depuis le site
    if (request.method === 'OPTIONS') return corsPreflight();

    try {
      if (request.method === 'POST' && url.pathname === '/test')
        return await routeTest(request, env);
      if (request.method === 'POST' && url.pathname === '/webhook')
        return await routeWebhook(request, env);
      return json({ erreur: 'Route inconnue' }, 404);
    } catch (e) {
      console.error('Erreur worker:', e.stack || e.message);
      return json({ erreur: 'Erreur interne', detail: e.message }, 500);
    }
  },
};

/* =====================================================================
   OUTILS HTTP
===================================================================== */
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-Webhook-Secret',
};
function corsPreflight() { return new Response(null, { status: 204, headers: CORS }); }
function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS },
  });
}

/* Vérification du secret partagé (webhooks Supabase + bouton test admin) */
function secretValide(request, env) {
  const recu = request.headers.get('X-Webhook-Secret') || '';
  return env.WEBHOOK_SECRET && recu === env.WEBHOOK_SECRET;
}

/* =====================================================================
   SUPABASE — REST service_role (côté serveur : le bon endroit)
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
async function sbInsert(env, table, lignes) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${table}`, {
    method: 'POST',
    headers: sbHeaders(env, { Prefer: 'return=minimal' }),
    body: JSON.stringify(lignes),
  });
  if (!r.ok) console.error(`Supabase INSERT ${table} → ${r.status}: ${await r.text()}`);
  return r.ok;
}
async function sbUpdate(env, chemin, patch) {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/${chemin}`, {
    method: 'PATCH',
    headers: sbHeaders(env, { Prefer: 'return=representation' }),
    body: JSON.stringify(patch),
  });
  if (!r.ok) { console.error(`Supabase PATCH ${chemin} → ${r.status}: ${await r.text()}`); return []; }
  return r.json();
}

/* =====================================================================
   TWILIO — REST via fetch + Basic auth (pas de SDK)
===================================================================== */
async function twilioEnvoyer(env, vers, corps) {
  const urlApi = `https://api.twilio.com/2010-04-01/Accounts/${env.TWILIO_ACCOUNT_SID}/Messages.json`;
  const auth = btoa(`${env.TWILIO_ACCOUNT_SID}:${env.TWILIO_AUTH_TOKEN}`);
  const form = new URLSearchParams({ To: vers, From: env.TWILIO_FROM_NUMBER, Body: corps });
  try {
    const r = await fetch(urlApi, {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    });
    const rep = await r.json().catch(() => ({}));
    if (r.ok) return { ok: true, sid: rep.sid || null };
    return { ok: false, sid: rep.sid || null, erreur: `${r.status} ${rep.code || ''} ${rep.message || ''}`.trim() };
  } catch (e) {
    return { ok: false, sid: null, erreur: e.message };
  }
}

/* Journal : CHAQUE tentative va dans sms_log */
async function loggerSms(env, { profile_id = null, contrat_id = null, type, to_number = null, body = null, twilio_sid = null, statut, erreur = null }) {
  await sbInsert(env, 'sms_log', [{ profile_id, contrat_id, type, to_number, body, twilio_sid, statut, erreur }]);
}

/* Envoi + journalisation en une étape */
async function envoyerEtLogger(env, { vers, corps, type, profile_id = null, contrat_id = null }) {
  const res = await twilioEnvoyer(env, vers, corps);
  await loggerSms(env, {
    profile_id, contrat_id, type,
    to_number: vers, body: corps,
    twilio_sid: res.sid,
    statut: res.ok ? 'envoye' : 'echec',
    erreur: res.ok ? null : res.erreur,
  });
  return res;
}

/* File d'envoi à concurrence limitée (5 en parallèle) */
async function enParallele(taches, limite = 5) {
  const resultats = [];
  let i = 0;
  async function ouvrier() {
    while (i < taches.length) {
      const idx = i++;
      resultats[idx] = await taches[idx]();
    }
  }
  await Promise.all(Array.from({ length: Math.min(limite, taches.length) }, ouvrier));
  return resultats;
}

/* =====================================================================
   MESSAGES — préfixe "C-Direct:", GSM-7 autant que possible.
   Mois SANS accents problématiques ("août" → "aout" : û n'est pas
   GSM-7 et ferait basculer tout le message en UCS-2 / segments de 70).
===================================================================== */
const MOIS = ['janv', 'fevr', 'mars', 'avr', 'mai', 'juin', 'juil', 'aout', 'sept', 'oct', 'nov', 'dec'];
function dateCourte(iso) {
  const [a, m, j] = String(iso).slice(0, 10).split('-').map(Number);
  return `${j} ${MOIS[m - 1]} ${a !== new Date().getFullYear() ? a : ''}`.trim();
}
function hhmm(t) { return String(t || '').slice(0, 5); }
const SUFFIXE_OPTOUT = ' Rep. ARRET pour vous desabonner.';

/* Premier SMS jamais envoyé à ce numéro ? (lookup sms_log) */
async function numerosDejaContactes(env, numeros) {
  if (!numeros.length) return new Set();
  const dedans = numeros.map(n => `"${n}"`).join(',');
  const lignes = await sbSelect(env, `sms_log?select=to_number&statut=eq.envoye&to_number=in.(${encodeURIComponent(dedans)})`);
  return new Set(lignes.map(l => l.to_number));
}

/* =====================================================================
   POST /webhook — Supabase Database Webhook (INSERT sur contrats).
   Payload : { type:'INSERT', table:'contrats', record:{…}, schema, old_record }
   1. Déduplication (id contrat + type d'évènement, fenêtre 10 min)
   2. Diffusion : TOUS les profils role='pharmacien' AND sms_optin=true
      (AUCUN autre filtrage en Phase 4)
   3. Confirmation à la pharmacie (si téléphone au profil)
===================================================================== */
async function routeWebhook(request, env) {
  if (!secretValide(request, env)) return json({ erreur: 'Non autorisé' }, 401);

  const payload = await request.json().catch(() => null);
  if (!payload || payload.type !== 'INSERT' || payload.table !== 'contrats' || !payload.record)
    return json({ ok: true, ignore: 'Évènement non géré en Phase 4' });

  const k = payload.record;
  if (k.statut && k.statut !== 'ouvert')
    return json({ ok: true, ignore: 'Contrat non ouvert' });

  /* ---- 1 · idempotence : Supabase peut réessayer le webhook ---- */
  const depuis = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const deja = await sbSelect(env,
    `sms_log?select=id&contrat_id=eq.${k.id}&type=eq.contrat_nouveau&created_at=gte.${encodeURIComponent(depuis)}&limit=1`);
  if (deja.length) return json({ ok: true, ignore: 'Doublon (retry webhook) — déjà traité' });

  /* marqueur immédiat : ferme la fenêtre de course entre deux retries */
  await loggerSms(env, { contrat_id: k.id, type: 'contrat_nouveau', statut: 'demarre', body: `Diffusion ${k.numero_reference}` });

  /* ---- 2 · destinataires + ville de la pharmacie ---- */
  const [pharmaciens, pharmacies] = await Promise.all([
    sbSelect(env, `profiles?select=id,telephone&role=eq.pharmacien&sms_optin=eq.true&telephone=not.is.null`),
    sbSelect(env, `profiles?select=id,telephone,ville,nom_pharmacie&id=eq.${k.pharmacie_id}`),
  ]);
  const pharmacie = pharmacies[0] || {};

  /* gabarit broadcast — ville bornée à 20 car. pour viser 1 segment GSM-7 */
  const ville = String(pharmacie.ville || 'Quebec').slice(0, 20);
  const base = `C-Direct: Nouveau contrat ${k.numero_reference} - ${ville}, ${dateCourte(k.date_contrat)}, ` +
               `${hhmm(k.heure_debut)}-${hhmm(k.heure_fin)}, ${Math.round(k.tarif_horaire)}$/h. ` +
               `Postulez: c-direct.ca/c/${k.numero_reference}`;

  /* premier SMS jamais envoyé à chacun de ces numéros ? */
  const tousNumeros = pharmaciens.map(p => p.telephone)
    .concat(pharmacie.telephone ? [pharmacie.telephone] : []);
  const dejaContactes = await numerosDejaContactes(env, tousNumeros);

  /* ---- 3 · diffusion (5 en parallèle, tout journalisé) ---- */
  const taches = pharmaciens.map(p => () => envoyerEtLogger(env, {
    vers: p.telephone,
    corps: base + (dejaContactes.has(p.telephone) ? '' : SUFFIXE_OPTOUT),
    type: 'contrat_nouveau',
    profile_id: p.id,
    contrat_id: k.id,
  }));
  const resultats = await enParallele(taches, 5);
  const nEnvoyes = resultats.filter(r => r && r.ok).length;

  /* ---- 4 · confirmation à la pharmacie ---- */
  let confirmation = null;
  if (pharmacie.telephone) {
    const corps = `C-Direct: Votre contrat ${k.numero_reference} du ${dateCourte(k.date_contrat)} est publie. ` +
                  `${nEnvoyes} pharmacien${nEnvoyes > 1 ? 's' : ''} notifie${nEnvoyes > 1 ? 's' : ''}. Suivi: c-direct.ca` +
                  (dejaContactes.has(pharmacie.telephone) ? '' : SUFFIXE_OPTOUT);
    confirmation = await envoyerEtLogger(env, {
      vers: pharmacie.telephone, corps,
      type: 'contrat_publie_confirmation',
      profile_id: pharmacie.id, contrat_id: k.id,
    });
  }

  return json({
    ok: true,
    contrat: k.numero_reference,
    pharmaciens_cibles: pharmaciens.length,
    sms_envoyes: nEnvoyes,
    confirmation_pharmacie: confirmation ? confirmation.ok : 'aucun téléphone au profil',
  });
}

/* =====================================================================
   POST /test — vérifier le tuyau sans toucher aux utilisateurs.
   Corps JSON : { "to": "+1XXXXXXXXXX" }
===================================================================== */
async function routeTest(request, env) {
  if (!secretValide(request, env)) return json({ erreur: 'Non autorisé' }, 401);
  const { to } = await request.json().catch(() => ({}));
  if (!/^\+1\d{10}$/.test(to || '')) return json({ erreur: 'Numéro invalide — format +1XXXXXXXXXX requis' }, 400);

  const corps = 'C-Direct: SMS test - le pipeline Supabase/Worker/Twilio fonctionne.';
  const res = await envoyerEtLogger(env, { vers: to, corps, type: 'test' });
  return json(res.ok ? { ok: true, sid: res.sid } : { ok: false, erreur: res.erreur }, res.ok ? 200 : 502);
}
