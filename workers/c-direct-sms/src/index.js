// =====================================================================
// C-DIRECT · PHASE 4 — Worker "c-direct-sms"
// Supabase Database Webhooks → ce Worker → Twilio (REST, sans SDK).
// AUCUN secret dans ce fichier : tout vient de `wrangler secret put`.
//   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER,
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, WEBHOOK_SECRET
// =====================================================================

import { distanceKm } from './fsa.js';

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
      if (request.method === 'POST' && url.pathname === '/confirmer')
        return await routeConfirmer(request, env);
      if (request.method === 'GET' && url.pathname === '/diag')
        return json({
          version: 'confirmer-pdf-2026-07-21b',
          resend: !!env.RESEND_API_KEY,
          resend_from: env.RESEND_FROM || 'C-Direct <notifications@c-direct.ca> (défaut)',
          supabase: !!env.SUPABASE_URL,
          twilio: !!env.TWILIO_ACCOUNT_SID,
          webhook_secret_set: !!env.WEBHOOK_SECRET,
        });
      if (request.method === 'GET' && url.pathname === '/diag-livraison'
          && url.searchParams.get('k') === 'diag-9f3a2c') {
        const kk = (await sbSelect(env, `contrats?select=*&numero_reference=eq.CD-100012`))[0];
        const cc = kk ? (await sbSelect(env, `candidatures?select=*&contrat_id=eq.${kk.id}&statut=eq.accepte&limit=1`))[0] : null;
        if (!kk || !cc) return json({ erreur: 'contrat/candidature test introuvable' });
        const envoi = await envoyerConfirmationContrat(env, kk, cc);
        const ids = [];
        if (envoi.pharmacien && envoi.pharmacien.id) ids.push({ role: 'pharmacien', id: envoi.pharmacien.id, to: envoi.pharmacien.to });
        if (envoi.pharmacie && envoi.pharmacie.id) ids.push({ role: 'pharmacie', id: envoi.pharmacie.id, to: envoi.pharmacie.to });
        await new Promise(r => setTimeout(r, 5000));
        const statuts = [];
        for (const it of ids) {
          const rr = await fetch(`https://api.resend.com/emails/${it.id}`, { headers: { Authorization: `Bearer ${env.RESEND_API_KEY}` } });
          const jj = await rr.json().catch(() => ({}));
          statuts.push({ role: it.role, to: it.to, last_event: jj.last_event || null, from: jj.from || null });
        }
        return json({ from: env.RESEND_FROM || 'C-Direct <notifications@c-direct.ca>', envoi, statuts });
      }
      if (request.method === 'POST' && url.pathname === '/twilio-inbound')
        return await routeTwilioInbound(request, env);
      return json({ erreur: 'Route inconnue' }, 404);
    } catch (e) {
      console.error('Erreur worker:', e.stack || e.message);
      return json({ erreur: 'Erreur interne', detail: e.message }, 500);
    }
  },

  /* Cron Triggers — voir wrangler.toml */
  async scheduled(event, env, ctx) {
    try {
      if (event.cron === '* * * * *') {
        await flushQueue(env);
      } else {
        const h = heureMontreal();
        if (h === 10) await cronDunning(env);        // 14/15 UTC → 10:00 locale
        if (h === 18) await cronRappelVeille(env);   // 22/23 UTC → 18:00 locale
      }
    } catch (e) {
      console.error('Erreur cron:', e.stack || e.message);
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

/* =====================================================================
   COURRIEL « CONTRAT CONFIRMÉ » + PDF joint (Resend) — bilingue
   Déclenché quand une candidature passe à 'accepte'. Sans dépendance :
   le PDF est fabriqué à la main (Helvetica, texte ASCII). N'envoie rien
   si RESEND_API_KEY est absent — donc inoffensif tant que le secret
   n'est pas configuré.
===================================================================== */
async function envoyerEmailResend(env, { to, subject, html, filename, pdfBase64 }) {
  if (!env.RESEND_API_KEY) return { ok: false, skip: 'RESEND_API_KEY absent' };
  if (!to) return { ok: false, skip: 'courriel manquant' };
  const body = {
    from: env.RESEND_FROM || 'C-Direct <notifications@c-direct.ca>',
    to: [to], subject, html,
  };
  if (pdfBase64) body.attachments = [{ filename: filename || 'contrat.pdf', content: pdfBase64 }];
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const txt = await r.text();
  let id = null; try { id = JSON.parse(txt).id; } catch (e) {}
  return { ok: r.ok, status: r.status, id, to, erreur: r.ok ? null : txt.slice(0, 300) };
}

/* repli ASCII (les polices standard du PDF n'ont pas toutes les accents) */
function foldAscii(s) {
  return String(s == null ? '' : s)
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^\x20-\x7E]/g, ' ');
}

/* PDF « soigné » sans librairie : 2 polices, couleurs, filets, logo vectoriel.
   Renvoie une chaîne base64 prête pour la pièce jointe Resend. */
/* CP1252 (WinAnsi) : garde les accents français en octets simples pour le PDF */
function cp1252(s) {
  const map = { '’': '', '‘': '', '“': '', '”': '',
                '–': '', '—': '', '…': '', '€': '' };
  return String(s == null ? '' : s).split('').map(ch => {
    const c = ch.charCodeAt(0);
    if (c <= 0xFF) return ch;      // Latin-1 (inclut é è à ç ê î ô û …) → même octet
    return map[ch] || ' ';
  }).join('');
}
const escPdf = t => cp1252(t).replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
function motsEnLignes(s, max) {
  const mots = String(s == null ? '' : s).split(/\s+/); const out = []; let cur = '';
  for (const m of mots) { if ((cur + ' ' + m).trim().length > max) { if (cur) out.push(cur.trim()); cur = m; } else cur += ' ' + m; }
  if (cur.trim()) out.push(cur.trim()); return out;
}
function assemblerPdf(flux) {
  const objets = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ' + flux.length + ' >>\nstream\n' + flux + 'endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>',
  ];
  let pdf = '%PDF-1.4\n'; const offs = [];
  objets.forEach((o, i) => { offs.push(pdf.length); pdf += (i + 1) + ' 0 obj\n' + o + '\nendobj\n'; });
  const xref = pdf.length;
  pdf += 'xref\n0 ' + (objets.length + 1) + '\n0000000000 65535 f \n';
  offs.forEach(o => { pdf += String(o).padStart(10, '0') + ' 00000 n \n'; });
  pdf += 'trailer\n<< /Size ' + (objets.length + 1) + ' /Root 1 0 R >>\nstartxref\n' + xref + '\n%%EOF';
  let bin = ''; for (let i = 0; i < pdf.length; i++) bin += String.fromCharCode(pdf.charCodeAt(i) & 0xff);
  return btoa(bin);
}
function pdfContratConfirme(t, d) {
  const VERT = '0.043 0.431 0.310', DARK = '0.106 0.149 0.125', GRIS = '0.42 0.49 0.45',
        LIGNE = '0.80 0.85 0.82', BG = '0.94 0.97 0.95', BLANC = '1 1 1';
  const o = [];
  const txt = (x, y, s, size, col, bold) => o.push(`BT /${bold ? 'F2' : 'F1'} ${size} Tf ${col} rg ${x} ${y} Td (${escPdf(s)}) Tj ET`);
  const largeur = (s, size) => cp1252(String(s)).length * size * 0.5;
  const txtR = (xr, y, s, size, col, bold) => txt(xr - largeur(s, size), y, s, size, col, bold);
  const rect = (x, y, w, h, col) => o.push(`${col} rg ${x} ${y} ${w} ${h} re f`);
  const cadre = (x, y, w, h, col) => o.push(`${col} RG 0.6 w ${x} ${y} ${w} ${h} re S`);
  const filet = (x1, y1, x2, col) => o.push(`${col} RG 0.6 w ${x1} ${y1} m ${x2} ${y1} l S`);

  // en-tête / lettre
  rect(0, 748, 612, 44, VERT);
  rect(40, 762, 20, 7, BLANC); rect(46.5, 755.5, 7, 20, BLANC);
  txt(74, 762, 'C-DIRECT', 15, BLANC, true);
  txt(74, 752, t.pdf_tag, 7, BLANC, false);
  txt(44, 728, 'MANDAT', 15, DARK, true);
  rect(44, 721, 74, 2.5, VERT);

  // colonne gauche : Facturé à / établissement
  let yl = 704;
  txt(44, yl, t.facture_a, 9, DARK, true); yl -= 13;
  txt(44, yl, d.pe_nom, 10, DARK, false); yl -= 12;
  motsEnLignes(d.pe_adr, 44).forEach(l => { txt(44, yl, l, 9, GRIS, false); yl -= 11; });
  yl -= 8;
  txt(44, yl, t.etablissement, 9, DARK, true); yl -= 13;
  txt(44, yl, d.pe_nom, 9.5, DARK, false); yl -= 11;
  motsEnLignes(d.pe_adr, 44).forEach(l => { txt(44, yl, l, 9, GRIS, false); yl -= 11; });
  if (d.pe_neq) { txt(44, yl, 'NEQ : ' + d.pe_neq, 9, GRIS, false); yl -= 11; }

  // colonne droite : Facturé par (encadré) + reçu
  cadre(326, 578, 242, 126, LIGNE);
  let yr = 692;
  txt(334, yr, t.facture_par, 9, DARK, true); yr -= 14;
  const paire = (a, b) => { txt(334, yr, a, 8.5, GRIS, false); txt(432, yr, String(b || '—'), 8.5, DARK, false); yr -= 12; };
  paire(t.remplacant, d.pn_nom);
  paire(t.profession, t.val_profession);
  paire('N° OPQ', d.pn_opq);
  paire(t.statut_l, t.val_statut);
  paire(t.province, t.val_province);
  paire('TPS', d.pn_tps);
  paire('TVQ', d.pn_tvq);
  paire(t.societe_l, d.pn_corp);
  let yre = 566;
  const recu = (a, b) => { txt(334, yre, a, 8.5, GRIS, false); txt(442, yre, String(b || '—'), 8.5, DARK, false); yre -= 12; };
  recu(t.recu, '—'); recu(t.contrat_l, d.ref); recu(t.emission, d.date_emission);

  let y = Math.min(yl, 528) - 6;

  // tableau des heures
  rect(44, y - 15, 524, 15, BG); cadre(44, y - 30, 524, 30, LIGNE); filet(44, y - 15, 568, LIGNE);
  txt(50, y - 11, t.th_date, 8.5, DARK, true); txt(190, y - 11, t.th_debut, 8.5, DARK, true);
  txt(320, y - 11, t.th_fin, 8.5, DARK, true); txtR(562, y - 11, t.th_heures, 8.5, DARK, true);
  txt(50, y - 26, d.contrat_date, 9.5, DARK, false); txt(190, y - 26, d.hd, 9.5, DARK, false);
  txt(320, y - 26, d.hf, 9.5, DARK, false); txtR(562, y - 26, d.heures, 9.5, DARK, false);
  y -= 46;

  // tableau des postes
  const hRows = d.lignes.length;
  rect(44, y - 15, 524, 15, BG);
  cadre(44, y - 15 - hRows * 17, 524, 15 + hRows * 17, LIGNE);
  filet(44, y - 15, 568, LIGNE);
  txt(50, y - 11, t.th_desc, 8.5, DARK, true); txtR(410, y - 11, t.th_qte, 8.5, DARK, true);
  txtR(490, y - 11, t.th_pu, 8.5, DARK, true); txtR(562, y - 11, t.th_montant, 8.5, DARK, true);
  let yp = y - 30;
  d.lignes.forEach((L, i) => {
    txt(50, yp, L.desc, 9.5, DARK, false); txtR(410, yp, L.qte, 9.5, DARK, false);
    txtR(490, yp, L.pu, 9.5, DARK, false); txtR(562, yp, L.montant, 9.5, DARK, false);
    if (i < hRows - 1) filet(44, yp - 6, 568, LIGNE);
    yp -= 17;
  });
  y = yp - 8;

  // totaux
  const tot = (a, b, bold) => { txt(408, y, a, 9.5, bold ? DARK : GRIS, bold); txtR(562, y, b, 9.5, DARK, bold); y -= 15; };
  tot(t.soustotal_l, d.soustotal, false);
  tot(t.tps_l, d.tps, false);
  tot(t.tvq_l, d.tvq, false);
  filet(408, y + 4, 568, LIGNE);
  tot(t.total_l, d.total, true);

  // pied
  y -= 6; filet(44, y, 568, LIGNE); y -= 15;
  motsEnLignes(t.note, 108).forEach(l => { txt(44, y, l, 8, GRIS, false); y -= 11; });
  txt(44, 46, 'c-direct.ca', 9.5, VERT, true);
  txtR(568, 46, t.signature, 8.5, GRIS, false);
  return assemblerPdf(o.join('\n'));
}
function argent(n) {
  n = Number(n) || 0;
  const p = n.toFixed(2).split('.');
  p[0] = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ' ');
  return p[0] + ',' + p[1] + ' $';
}

function heuresEntre(hd, hf) {
  const [h1, m1] = String(hd || '0:0').split(':').map(Number);
  const [h2, m2] = String(hf || '0:0').split(':').map(Number);
  let h = (h2 * 60 + m2 - (h1 * 60 + m1)) / 60;
  if (h < 0) h += 24;
  return Math.round(h * 100) / 100;
}

const T_CONF = {
  fr: {
    subject: r => 'Contrat confirmé — ' + r,
    salut: 'Bonjour',
    intro: 'Voici votre contrat confirmé. Le mandat (détail des honoraires) est joint en PDF.',
    ref: 'Référence', pharmacie: 'Pharmacie', pharmacien: 'Pharmacien(ne)', nom: 'Nom',
    pdf_tag: 'Réseau de remplacement en pharmacie',
    facture_a: 'Facturé à :', etablissement: 'Nom et adresse de l\'établissement :',
    facture_par: 'Facturé par :', remplacant: 'Remplaçant :', profession: 'Profession :',
    val_profession: 'Pharmacien(ne)', statut_l: 'Statut :', val_statut: 'Indépendant',
    province: 'Province :', val_province: 'Québec', societe_l: 'Société :',
    recu: 'N° de reçu :', contrat_l: 'Contrat :', emission: 'Date d\'émission :',
    th_date: 'Date', th_debut: 'Heure début', th_fin: 'Heure fin', th_heures: 'Heures',
    th_desc: 'Description', th_qte: 'Qté', th_pu: 'Prix unitaire', th_montant: 'Montant',
    l_pharmacien: 'Pharmacien(ne)', l_km: 'Frais de déplacement (aller-retour)',
    l_perdiem: 'Per diem', l_heberg: 'Hébergement',
    soustotal_l: 'Sous-total', tps_l: 'TPS (5,000 %)', tvq_l: 'TVQ (9,975 %)', total_l: 'Total',
    note: 'Mandat de confirmation. La facture finale, avec kilométrage réel et taxes applicables, est émise à la complétion du contrat. Paiement Interac direct — aucun frais ne transite par C-Direct.',
    signature: '— C-Direct · 0 % commission',
  },
  en: {
    subject: r => 'Confirmed contract — ' + r,
    salut: 'Hello',
    intro: 'Here is your confirmed contract. The mandate (fee breakdown) is attached as a PDF.',
    ref: 'Reference', pharmacie: 'Pharmacy', pharmacien: 'Pharmacist', nom: 'Name',
    pdf_tag: 'Pharmacy relief network',
    facture_a: 'Billed to:', etablissement: 'Establishment name and address:',
    facture_par: 'Billed by:', remplacant: 'Relief pharmacist:', profession: 'Profession:',
    val_profession: 'Pharmacist', statut_l: 'Status:', val_statut: 'Independent',
    province: 'Province:', val_province: 'Quebec', societe_l: 'Company:',
    recu: 'Receipt No.:', contrat_l: 'Contract:', emission: 'Issue date:',
    th_date: 'Date', th_debut: 'Start', th_fin: 'End', th_heures: 'Hours',
    th_desc: 'Description', th_qte: 'Qty', th_pu: 'Unit price', th_montant: 'Amount',
    l_pharmacien: 'Pharmacist', l_km: 'Travel (round trip)',
    l_perdiem: 'Per diem', l_heberg: 'Lodging',
    soustotal_l: 'Subtotal', tps_l: 'GST (5.000 %)', tvq_l: 'QST (9.975 %)', total_l: 'Total',
    note: 'Confirmation mandate. The final invoice, with actual mileage and applicable taxes, is issued upon contract completion. Direct Interac payment — no money transits through C-Direct.',
    signature: '— C-Direct · 0% commission',
  },
};

// Registre fiscal (repris de fiche.js) : numéros de taxes par courriel.
// Sert de repli quand le profil du pharmacien n'a pas encore ses numéros.
const REGISTRE_FISCAL = {
  'edouardmalak@gmail.com': { tps: '845655646 RT0001', tvq: '1219458181 TQ0002', corp: 'Edouard Abdel Malak Pharmacien Inc' },
};
function normCourriel(e) { return String(e || '').toLowerCase().trim().replace(/\+[^@]*(?=@)/, ''); }

async function envoyerConfirmationContrat(env, k, c) {
  if (!env.RESEND_API_KEY) return { ok: false, skip: 'RESEND_API_KEY absent' };
  const champs = '*';   // tolérant : lit tps/tvq/societe s'ils existent, sinon absents
  const [pnA, peA] = await Promise.all([
    sbSelect(env, `profiles?select=${champs}&id=eq.${c.pharmacien_id}`),
    sbSelect(env, `profiles?select=${champs}&id=eq.${k.pharmacie_id}`),
  ]);
  const pn = pnA[0] || {}, pe = peA[0] || {};
  const fiscal = REGISTRE_FISCAL[normCourriel(pn.courriel)] || {};
  const pnTps = (pn.tps && String(pn.tps).trim()) || fiscal.tps || '';
  const pnTvq = (pn.tvq && String(pn.tvq).trim()) || fiscal.tvq || '';
  const pnCorp = (pn.societe && String(pn.societe).trim()) || fiscal.corp || '';
  let taux_km = 0.70, per_diem_jour = 50, heberg_jour = 250;
  try {
    const rg = (await sbSelect(env, 'regles_reseau?select=taux_km,per_diem_jour,hebergement_jour&id=eq.1'))[0];
    if (rg) { taux_km = Number(rg.taux_km) || 0.70; per_diem_jour = Number(rg.per_diem_jour) || 50; heberg_jour = Number(rg.hebergement_jour) || 250; }
  } catch (e) {}

  const tarif = Number(c.tarif_propose ?? k.tarif_horaire) || 0;
  const hd = c.heure_debut_proposee || k.heure_debut;
  const hf = c.heure_fin_proposee || k.heure_fin;
  const heures = heuresEntre(hd, hf);
  const base = Math.round(heures * tarif * 100) / 100;
  const kmAR = (c.distance_km != null) ? Number(c.distance_km) * 2 : 0;
  const montantKm = Math.round(kmAR * taux_km * 100) / 100;
  const perdiem = k.per_diem ? per_diem_jour : 0;
  const heberg = k.hebergement ? heberg_jour : 0;
  const soustotal = base + montantKm + perdiem + heberg;
  const taxable = !!pnTps;   // taxes seulement si numéro TPS au dossier (profil ou registre)
  const tps = taxable ? Math.round(soustotal * 0.05 * 100) / 100 : 0;
  const tvq = taxable ? Math.round(soustotal * 0.09975 * 100) / 100 : 0;
  const total = Math.round((soustotal + tps + tvq) * 100) / 100;
  const nomPn = `${pn.prenom || ''} ${pn.nom || ''}`.trim() || '—';
  const nomPe = pe.nom_pharmacie || '—';
  const adr = [pe.adresse, pe.ville, pe.code_postal].filter(Boolean).join(', ') || '—';
  const emission = new Date().toISOString().slice(0, 10);

  const construire = (lang) => {
    const t = T_CONF[lang === 'en' ? 'en' : 'fr'];
    const lignes = [{ desc: t.l_pharmacien, qte: `${heures} h`, pu: argent(tarif), montant: argent(base) }];
    if (kmAR > 0) lignes.push({ desc: t.l_km, qte: `${kmAR} km`, pu: argent(taux_km), montant: argent(montantKm) });
    if (perdiem > 0) lignes.push({ desc: t.l_perdiem, qte: '1', pu: argent(per_diem_jour), montant: argent(perdiem) });
    if (heberg > 0) lignes.push({ desc: t.l_heberg, qte: '1', pu: argent(heberg_jour), montant: argent(heberg) });
    const d = {
      ref: k.numero_reference, date_emission: emission,
      pe_nom: nomPe, pe_adr: adr, pe_neq: pe.neq || '',
      pn_nom: nomPn, pn_opq: pn.numero_opq || '', pn_tps: pnTps, pn_tvq: pnTvq, pn_corp: pnCorp,
      contrat_date: String(k.date_contrat), hd: hhmm(hd), hf: hhmm(hf), heures: `${heures} h`,
      lignes,
      soustotal: argent(soustotal), tps: argent(tps), tvq: argent(tvq), total: argent(total),
    };
    const pdf = pdfContratConfirme(t, d);
    const html =
      `<div style="font-family:Arial,sans-serif;color:#12211b;max-width:560px">` +
      `<p>${t.salut},</p><p>${t.intro}</p>` +
      `<p style="font-size:14px"><b>${t.ref} :</b> ${k.numero_reference}<br><b>${t.total_l} :</b> ${argent(total)}</p>` +
      `<p style="font-size:12px;color:#6b7c74">${t.note}</p><p>${t.signature}</p></div>`;
    return { t, pdf, html };
  };

  const out = {};
  if (pn.courriel) {
    const b = construire(pn.langue);
    out.pharmacien = await envoyerEmailResend(env, {
      to: pn.courriel, subject: b.t.subject(k.numero_reference), html: b.html,
      filename: `C-Direct-${k.numero_reference}.pdf`, pdfBase64: b.pdf,
    });
  }
  if (pe.courriel) {
    const b = construire(pe.langue);
    out.pharmacie = await envoyerEmailResend(env, {
      to: pe.courriel, subject: b.t.subject(k.numero_reference), html: b.html,
      filename: `C-Direct-${k.numero_reference}.pdf`, pdfBase64: b.pdf,
    });
  }
  return { ok: true, ...out };
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
   HEURES DE SILENCE (5.4) + FILE D'ATTENTE (5.2)
   Les messages destinés aux PHARMACIENS créés 21:00–07:00
   America/Montreal attendent 07:00. Confirmations pharmacie et
   rappel_veille (18:00) : non concernés.
===================================================================== */
function partiesMontreal(d = new Date()) {
  const f = new Intl.DateTimeFormat('fr-CA', {
    timeZone: 'America/Montreal',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  });
  return Object.fromEntries(f.formatToParts(d).map(p => [p.type, p.value]));
}
function heureMontreal(d = new Date()) { return (+partiesMontreal(d).hour) % 24; }

function enSilence(d = new Date()) {
  const h = heureMontreal(d);
  return h >= 21 || h < 7;
}

/* le prochain 07:00 America/Montreal, en instant UTC réel */
function prochain0700Utc(depuis = new Date()) {
  const p = partiesMontreal(depuis);
  /* décalage Montréal↔UTC à cet instant (≈ 4 ou 5 h, arrondi au quart d'heure) */
  const mur = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute);
  const decalage = Math.round((depuis.getTime() - mur) / 900000) * 900000;
  let cible = Date.UTC(+p.year, +p.month - 1, +p.day, 7, 0, 0) + decalage;
  if (+p.hour >= 7) cible += 24 * 3600 * 1000;   // déjà passé 07:00 → demain
  return new Date(cible);
}

/* instant d'envoi ajusté : jamais pendant les heures de silence */
function ajusterEnvoi(envisage) {
  return enSilence(envisage) ? prochain0700Utc(envisage) : envisage;
}

/* mise en file (pharmaciens seulement) */
async function enfilerSms(env, lignes) {
  if (!lignes.length) return true;
  return sbInsert(env, 'sms_queue', lignes);
}

/* envoi pharmacien : immédiat hors silence, sinon en file jusqu'à 07:00 */
async function envoyerAuPharmacien(env, { profile_id, contrat_id = null, pharmacie_id = null, vers, corps, type, ville = null }) {
  if (!enSilence()) {
    return envoyerEtLogger(env, { vers, corps, type, profile_id, contrat_id });
  }
  await enfilerSms(env, [{
    profile_id, contrat_id, pharmacie_id, to_number: vers, type, corps, ville,
    envoyer_apres: prochain0700Utc().toISOString(),
  }]);
  return { ok: true, differe: true };
}

/* =====================================================================
   VIDAGE DE LA FILE — Cron chaque minute.
   · Réclamation atomique (statut attente→envoi, filtre PostgREST)
   · Par pharmacien : 3+ contrats d'une MÊME pharmacie dus ensemble
     → UN digest (lot sms_batch, page /nouveaux/{batch_id}) ;
     1–2 → SMS individuels normaux. Autres types : individuels.
===================================================================== */
async function flushQueue(env) {
  const nowIso = new Date().toISOString();
  const rows = await sbUpdate(env,
    `sms_queue?statut=eq.attente&envoyer_apres=lte.${encodeURIComponent(nowIso)}`,
    { statut: 'envoi' });
  if (!rows.length) return { traite: 0 };

  /* suffixe opt-out : numéros jamais contactés */
  const dejaContactes = await numerosDejaContactes(env, [...new Set(rows.map(r => r.to_number))]);
  const suffixe = n => (dejaContactes.has(n) ? '' : SUFFIXE_OPTOUT);

  /* regroupement par pharmacien */
  const parPharmacien = new Map();
  for (const r of rows) {
    if (!parPharmacien.has(r.profile_id)) parPharmacien.set(r.profile_id, []);
    parPharmacien.get(r.profile_id).push(r);
  }

  /* lots par pharmacie (partagés entre pharmaciens) : créés à la demande */
  const batchParPharmacie = new Map();   // pharmacie_id → {id, contratIds:Set}
  const taches = [];
  const majStatut = [];                  // {ids, statut, batch_id}

  for (const [, lignes] of parPharmacien) {
    const diffusions = lignes.filter(l => l.type === 'contrat_nouveau');
    const autres = lignes.filter(l => l.type !== 'contrat_nouveau');

    /* diffusions groupées par pharmacie d'origine */
    const parPharmacie = new Map();
    for (const l of diffusions) {
      const cle = l.pharmacie_id || 'x';
      if (!parPharmacie.has(cle)) parPharmacie.set(cle, []);
      parPharmacie.get(cle).push(l);
    }

    for (const [pharmacieId, groupe] of parPharmacie) {
      if (groupe.length >= 3 && pharmacieId !== 'x') {
        /* ---- DIGEST ---- */
        if (!batchParPharmacie.has(pharmacieId)) {
          batchParPharmacie.set(pharmacieId, { id: crypto.randomUUID(), contratIds: new Set() });
        }
        const lot = batchParPharmacie.get(pharmacieId);
        groupe.forEach(l => lot.contratIds.add(l.contrat_id));
        taches.push(async () => {
          const infos = await sbSelect(env,
            `contrats?select=date_contrat,tarif_horaire&id=in.(${groupe.map(l => l.contrat_id).join(',')})`);
          const dates = infos.map(i => i.date_contrat).sort();
          const tarifs = infos.map(i => Math.round(i.tarif_horaire)).sort((a, b) => a - b);
          const tarifTxt = tarifs[0] === tarifs[tarifs.length - 1]
            ? `${tarifs[0]}` : `${tarifs[0]}-${tarifs[tarifs.length - 1]}`;
          const corps = `C-Direct: ${groupe.length} nouveaux contrats - ${groupe[0].ville || 'Quebec'}, ` +
            `du ${dateCourte(dates[0])} au ${dateCourte(dates[dates.length - 1])}, ${tarifTxt}$/h. ` +
            `Voir: c-direct.ca/nouveaux/${lot.id}` + suffixe(groupe[0].to_number);
          const res = await envoyerEtLogger(env, {
            vers: groupe[0].to_number, corps, type: 'contrat_digest',
            profile_id: groupe[0].profile_id, contrat_id: null,
          });
          majStatut.push({ ids: groupe.map(l => l.id), statut: res.ok ? 'groupe' : 'echec', batch_id: lot.id });
          return res;
        });
      } else {
        /* ---- individuels ---- */
        for (const l of groupe) {
          taches.push(async () => {
            const res = await envoyerEtLogger(env, {
              vers: l.to_number, corps: (l.corps || '') + suffixe(l.to_number),
              type: l.type, profile_id: l.profile_id, contrat_id: l.contrat_id,
            });
            majStatut.push({ ids: [l.id], statut: res.ok ? 'envoye' : 'echec', batch_id: null });
            return res;
          });
        }
      }
    }

    /* messages différés non-diffusion (heures de silence) */
    for (const l of autres) {
      taches.push(async () => {
        const res = await envoyerEtLogger(env, {
          vers: l.to_number, corps: (l.corps || '') + suffixe(l.to_number),
          type: l.type, profile_id: l.profile_id, contrat_id: l.contrat_id,
        });
        majStatut.push({ ids: [l.id], statut: res.ok ? 'envoye' : 'echec', batch_id: null });
        return res;
      });
    }
  }

  /* créer les lots AVANT les envois (la page doit exister au clic) */
  for (const [pharmacieId, lot] of batchParPharmacie) {
    await sbInsert(env, 'sms_batch', [{ id: lot.id, pharmacie_id: pharmacieId, contrat_ids: [...lot.contratIds] }]);
  }

  await enParallele(taches, 5);

  /* statuts finaux de la file */
  for (const m of majStatut) {
    await sbUpdate(env, `sms_queue?id=in.(${m.ids.join(',')})`,
      m.batch_id ? { statut: m.statut, batch_id: m.batch_id } : { statut: m.statut });
  }
  return { traite: rows.length };
}

/* =====================================================================
   CRON QUOTIDIEN 18:00 America/Montreal — RAPPEL VEILLE
   Chaque contrat ATTRIBUÉ daté de demain → SMS au pharmacien retenu
   avec adresse, horaire convenu, notes d'accès, logiciel, cell du
   propriétaire. Envoyé à 18:00 : hors heures de silence par définition.
   (Message volontairement complet → souvent 2 segments, assumé.)
===================================================================== */
async function cronRappelVeille(env) {
  const p = partiesMontreal();
  const demainUtc = new Date(Date.UTC(+p.year, +p.month - 1, +p.day + 1));
  const demain = demainUtc.toISOString().slice(0, 10);

  const contrats = await sbSelect(env, `contrats?select=*&statut=eq.attribue&date_contrat=eq.${demain}`);
  let envoyes = 0;

  for (const k of contrats) {
    if (await dejaTraite(env, `cron:rappel_veille:${k.id}:${demain}`)) continue;

    const cands = await sbSelect(env,
      `candidatures?select=pharmacien_id,tarif_propose,heure_debut_proposee,heure_fin_proposee&contrat_id=eq.${k.id}&statut=eq.accepte&limit=1`);
    const c = cands[0];
    if (!c) continue;
    const [pharmacien, pharmacie] = await Promise.all([
      chargerProfil(env, c.pharmacien_id), chargerProfil(env, k.pharmacie_id),
    ]);
    if (!pharmacien?.telephone || pharmacien.sms_optin === false) continue;

    const hd = hhmm(c.heure_debut_proposee || k.heure_debut);
    const hf = hhmm(c.heure_fin_proposee || k.heure_fin);
    const tarif = Math.round(c.tarif_propose ?? k.tarif_horaire);
    const morceaux = [
      `C-Direct: Rappel - ${k.numero_reference} demain a ${pharmacie?.nom_pharmacie || 'la pharmacie'}, ` +
      `${pharmacie?.adresse || ''}, ${pharmacie?.ville || ''}. ${hd}-${hf}, ${tarif}$/h.`,
    ];
    if (pharmacie?.notes_acces) morceaux.push(String(pharmacie.notes_acces).slice(0, 60) + '.');
    if (pharmacie?.logiciel) morceaux.push(`Logiciel: ${pharmacie.logiciel}.`);
    if (pharmacie?.cell_proprietaire) morceaux.push(`Cell proprio: ${pharmacie.cell_proprietaire}.`);

    const res = await envoyerEtLogger(env, {
      vers: pharmacien.telephone, corps: morceaux.join(' '),
      type: 'rappel_veille', profile_id: pharmacien.id, contrat_id: k.id,
    });
    if (res.ok) envoyes++;
  }
  return { contrats: contrats.length, envoyes };
}

/* =====================================================================
   CRON QUOTIDIEN 10:00 America/Montreal — RELANCES DE PAIEMENT
   Factures en_retard : relance tous les 7 jours, MAX 3, puis
   signalement admin (sms_log type rappel_paiement_max).
   (La 1re relance part du webhook factures UPDATE → en_retard.)
===================================================================== */
async function cronDunning(env) {
  const factures = await sbSelect(env,
    `factures?select=id,numero_facture,total,date_echeance,candidature_id&statut=eq.en_retard`);
  let relances = 0, signalements = 0;

  for (const f of factures) {
    const numero = 'F-' + String(f.numero_facture).padStart(6, '0');
    const motif = encodeURIComponent(`*${numero}*`);
    const envois = await sbSelect(env,
      `sms_log?select=created_at&type=eq.rappel_paiement&statut=eq.envoye&body=like.${motif}&order=created_at.desc`);

    if (envois.length >= 3) {
      /* plafond atteint → signaler l'admin UNE fois */
      const dejaSignale = await sbSelect(env,
        `sms_log?select=id&type=eq.rappel_paiement_max&body=eq.${encodeURIComponent(numero)}&limit=1`);
      if (!dejaSignale.length) {
        await loggerSms(env, {
          type: 'rappel_paiement_max', statut: 'signale', body: numero,
          erreur: `3 relances envoyées sans paiement — intervention admin requise`,
        });
        signalements++;
      }
      continue;
    }
    /* relance si aucune dans les 7 derniers jours */
    const derniere = envois[0] ? new Date(envois[0].created_at).getTime() : 0;
    if (Date.now() - derniere < 7 * 24 * 3600 * 1000) continue;

    const res = await relancerFacture(env, f);
    if (res.ok) relances++;
  }
  return { factures: factures.length, relances, signalements };
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
  if (!payload || !payload.record) return json({ ok: true, ignore: 'Payload vide' });
  const { table, type: evt, record, old_record } = payload;

  /* ---- matrice du cycle de vie (5.3) ---- */
  if (table === 'contrats' && evt === 'INSERT')
    return diffusionNouveauContrat(env, record);
  if (table === 'contrats' && evt === 'UPDATE')
    return evenementContrat(env, record, old_record || {});
  if (table === 'candidatures' && evt === 'INSERT')
    return candidatureNouvelle(env, record);
  if (table === 'candidatures' && evt === 'UPDATE')
    return candidatureMaj(env, record, old_record || {});
  if (table === 'factures' && evt === 'UPDATE')
    return factureMaj(env, record, old_record || {});

  return json({ ok: true, ignore: `Évènement non géré (${table}/${evt})` });
}

/* =====================================================================
   POST /confirmer — appelé par le SITE juste après une acceptation.
   Plus fiable que les Database Webhooks : le navigateur déclenche
   directement l'envoi. Authentifié par le jeton Supabase de l'usager
   (pas de secret partagé côté client). Envoie le courriel « contrat
   confirmé » + PDF aux deux parties. Idempotent (fenêtre 10 min).
   Corps : { ref: "CD-XXXXXX" }  ·  En-tête : Authorization: Bearer <jwt>
===================================================================== */
async function routeConfirmer(request, env) {
  try {
    const token = (request.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!token) return json({ erreur: 'Non authentifié' }, 401);

    // 1) valider le jeton → usager
    const ru = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${token}` },
    });
    if (!ru.ok) return json({ erreur: 'Jeton invalide' }, 401);
    const user = await ru.json();

    const corps = await request.json().catch(() => ({}));
    const ref = String(corps.ref || '').toUpperCase();
    if (!ref) return json({ erreur: 'Référence manquante' }, 400);

    if (await dejaTraite(env, `confirmer:${ref}`))
      return json({ ok: true, ignore: 'Confirmation déjà envoyée' });

    // 2) contrat + candidature acceptée (service_role : lecture serveur)
    const ks = await sbSelect(env, `contrats?select=*&numero_reference=eq.${encodeURIComponent(ref)}`);
    const k = ks[0];
    if (!k) return json({ erreur: 'Contrat introuvable' }, 404);
    const cs = await sbSelect(env, `candidatures?select=*&contrat_id=eq.${k.id}&statut=eq.accepte&limit=1`);
    const c = cs[0];
    if (!c) return json({ erreur: 'Aucune candidature acceptée' }, 409);

    // 3) autorisation : pharmacie propriétaire, pharmacien retenu, ou admin
    const profs = await sbSelect(env, `profiles?select=id,role&id=eq.${user.id}`);
    const role = profs[0] ? profs[0].role : null;
    const autorise = user.id === k.pharmacie_id || user.id === c.pharmacien_id || role === 'admin';
    if (!autorise) return json({ erreur: 'Non autorisé pour ce contrat' }, 403);

    // 4) envoi (courriel bilingue + PDF)
    const res = await envoyerConfirmationContrat(env, k, c);
    return json({ ok: true, contrat: ref, confirmation: res });
  } catch (e) {
    console.error('routeConfirmer:', e.stack || e.message);
    return json({ erreur: 'Erreur interne', detail: e.message }, 500);
  }
}

/* Idempotence générique : marqueur 'dedupe' dans sms_log, clé exacte,
   fenêtre 10 min (Supabase peut réessayer les webhooks). */
async function dejaTraite(env, cle) {
  const depuis = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const l = await sbSelect(env,
    `sms_log?select=id&type=eq.dedupe&body=eq.${encodeURIComponent(cle)}&created_at=gte.${encodeURIComponent(depuis)}&limit=1`);
  if (l.length) return true;
  await loggerSms(env, { type: 'dedupe', statut: 'marqueur', body: cle });
  return false;
}

/* charges utiles fréquentes */
const CHAMPS_PROFIL = 'id,telephone,sms_optin,prenom,nom,ville,nom_pharmacie,adresse,code_postal,logiciel,notes_acces,cell_proprietaire';
async function chargerContrat(env, id) { return (await sbSelect(env, `contrats?select=*&id=eq.${id}`))[0]; }
async function chargerProfil(env, id) { return (await sbSelect(env, `profiles?select=${CHAMPS_PROFIL}&id=eq.${id}`))[0]; }
const initiale = nom => (nom ? nom.trim().charAt(0).toUpperCase() + '.' : '');

/* =====================================================================
   contrats INSERT — diffusion filtrée (5.1) mise en file (5.2/5.4)
===================================================================== */
async function diffusionNouveauContrat(env, k) {
  if (k.statut && k.statut !== 'ouvert')
    return json({ ok: true, ignore: 'Contrat non ouvert' });
  if (await dejaTraite(env, `contrats:INSERT:${k.id}`))
    return json({ ok: true, ignore: 'Doublon (retry webhook) — déjà traité' });

  /* ---- 2 · candidats + contexte (pharmacie, règles, disponibilités) ---- */
  const cibles = await ciblesFiltrees(env, k);
  const { retenus, pharmacie } = cibles;

  /* ---- 3 · mise en FILE des diffusions pharmaciens (5.2 + 5.4) :
     tampon ~5 min pour le groupage, décalé à 07:00 si heures de
     silence. Le Cron du Worker vide la file chaque minute (le suffixe
     opt-out du premier SMS est appliqué au moment de l'envoi). ---- */
  const envoiPrevu = ajusterEnvoi(new Date(Date.now() + 5 * 60 * 1000)).toISOString();
  await enfilerSms(env, retenus.map(r => ({
    profile_id: r.p.id,
    contrat_id: k.id,
    pharmacie_id: k.pharmacie_id,
    to_number: r.p.telephone,
    type: 'contrat_nouveau',
    corps: r.corps,
    ville: String(pharmacie.ville || 'Quebec').slice(0, 20),
    envoyer_apres: envoiPrevu,
  })));
  const nEnvoyes = retenus.length;   // mis en file — la confirmation annonce le compte

  /* suffixe premier-SMS pour la confirmation pharmacie (immédiate) */
  const dejaContactes = await numerosDejaContactes(env,
    pharmacie.telephone ? [pharmacie.telephone] : []);

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
    pharmaciens_evalues: cibles.nEvalues,
    retenus: retenus.length,
    filtres: cibles.nFiltres,
    sms_envoyes: nEnvoyes,
    confirmation_pharmacie: confirmation ? confirmation.ok : 'aucun téléphone au profil',
  });
}

/* =====================================================================
   5.1 · CIBLAGE FILTRÉ — remplace la diffusion à tous.
   Critères (chaque critère est IGNORÉ si la donnée manque — un profil
   incomplet ou un calendrier non tenu ne bloque jamais) :
     · distance FSA(pharmacien, pharmacie) <= rayon_deplacement_km
     · tarif_horaire >= tarif_horaire_min du pharmacien
     · logiciel de la pharmacie ∈ logiciels du pharmacien
     · si le pharmacien a DES disponibilités ce mois-là → il en faut
       une le date_contrat
   Chaque exclusion est journalisée : statut 'filtre' + raison.
   Message par destinataire : km A/R + montant km quand calculables.
===================================================================== */
async function ciblesFiltrees(env, k) {
  const moisDebut = String(k.date_contrat).slice(0, 8) + '01';
  const finMois = new Date(Date.UTC(+String(k.date_contrat).slice(0, 4), +String(k.date_contrat).slice(5, 7), 0));
  const moisFin = finMois.toISOString().slice(0, 10);

  const [pharmaciens, pharmacies, reglesL] = await Promise.all([
    sbSelect(env, `profiles?select=id,telephone,code_postal,rayon_deplacement_km,tarif_horaire_min,logiciels&role=eq.pharmacien&sms_optin=eq.true&approuve=eq.true&telephone=not.is.null`),
    sbSelect(env, `profiles?select=id,telephone,ville,nom_pharmacie,code_postal,logiciel&id=eq.${k.pharmacie_id}`),
    sbSelect(env, `regles_reseau?select=taux_km&id=eq.1`),
  ]);
  const pharmacie = pharmacies[0] || {};
  const tauxKm = parseFloat((reglesL[0] || {}).taux_km) || 0.70;

  /* disponibilités du mois pour tous les candidats (1 requête) */
  const ids = pharmaciens.map(p => p.id);
  let disposParPh = new Map();
  if (ids.length) {
    const dispos = await sbSelect(env,
      `disponibilites?select=pharmacien_id,date_dispo&date_dispo=gte.${moisDebut}&date_dispo=lte.${moisFin}&pharmacien_id=in.(${ids.join(',')})`);
    for (const d of dispos) {
      if (!disposParPh.has(d.pharmacien_id)) disposParPh.set(d.pharmacien_id, new Set());
      disposParPh.get(d.pharmacien_id).add(String(d.date_dispo));
    }
  }

  const ville = String(pharmacie.ville || 'Quebec').slice(0, 20);
  const retenus = [], exclusions = [];

  for (const p of pharmaciens) {
    /* 1 · distance (ignoré si l'un des codes postaux manque) */
    const km = distanceKm(p.code_postal, pharmacie.code_postal);
    if (km != null && p.rayon_deplacement_km != null && km > p.rayon_deplacement_km) {
      exclusions.push({ p, raison: `distance ${km} km > rayon ${p.rayon_deplacement_km} km` }); continue;
    }
    /* 2 · tarif plancher personnel (ignoré si non renseigné) */
    if (p.tarif_horaire_min != null && parseFloat(k.tarif_horaire) < parseFloat(p.tarif_horaire_min)) {
      exclusions.push({ p, raison: `tarif ${k.tarif_horaire}$ < min ${p.tarif_horaire_min}$` }); continue;
    }
    /* 3 · logiciel (ignoré si l'une des listes est vide) */
    if (pharmacie.logiciel && Array.isArray(p.logiciels) && p.logiciels.length &&
        !p.logiciels.includes(pharmacie.logiciel)) {
      exclusions.push({ p, raison: `logiciel ${pharmacie.logiciel} non maitrise` }); continue;
    }
    /* 4 · disponibilités : un calendrier non tenu ne bloque jamais */
    const sesDispos = disposParPh.get(p.id);
    if (sesDispos && sesDispos.size && !sesDispos.has(String(k.date_contrat))) {
      exclusions.push({ p, raison: 'indispo (calendrier tenu, date absente)' }); continue;
    }

    /* message par destinataire — km A/R + montant quand calculables */
    let corps;
    if (km != null) {
      const kmAR = km * 2;
      const montant = Math.round(kmAR * tauxKm);
      corps = `C-Direct: Nouveau contrat ${k.numero_reference} - ${ville}, ${dateCourte(k.date_contrat)}, ` +
              `${Math.round(k.tarif_horaire)}$/h (+${kmAR} km = ${montant}$ km). Postulez: c-direct.ca/c/${k.numero_reference}`;
    } else {
      corps = `C-Direct: Nouveau contrat ${k.numero_reference} - ${ville}, ${dateCourte(k.date_contrat)}, ` +
              `${Math.round(k.tarif_horaire)}$/h. Postulez: c-direct.ca/c/${k.numero_reference}`;
    }
    retenus.push({ p, corps, km });
  }

  /* journal des exclus : statut 'filtre' + raison (type contrat_nouveau) */
  if (exclusions.length) {
    await sbInsert(env, 'sms_log', exclusions.map(x => ({
      profile_id: x.p.id, contrat_id: k.id, type: 'contrat_nouveau',
      to_number: x.p.telephone, body: null, twilio_sid: null,
      statut: 'filtre', erreur: x.raison,
    })));
  }

  return { retenus, pharmacie, nEvalues: pharmaciens.length, nFiltres: exclusions.length };
}

/* =====================================================================
   5.3 · MATRICE DU CYCLE DE VIE
   Pharmacien : via envoyerAuPharmacien (heures de silence respectées).
   Pharmacie : envoi immédiat (confirmations opérationnelles).
===================================================================== */

/* ---- candidatures INSERT → pharmacie ---- */
async function candidatureNouvelle(env, c) {
  if (await dejaTraite(env, `candidatures:INSERT:${c.id}`))
    return json({ ok: true, ignore: 'Doublon' });

  const k = await chargerContrat(env, c.contrat_id);
  if (!k) return json({ ok: true, ignore: 'Contrat introuvable' });
  const [pharmacie, pharmacien] = await Promise.all([
    chargerProfil(env, k.pharmacie_id), chargerProfil(env, c.pharmacien_id),
  ]);
  if (!pharmacie || !pharmacie.telephone)
    return json({ ok: true, ignore: 'Pharmacie sans téléphone' });

  const qui = `${pharmacien?.prenom || 'Un pharmacien'} ${initiale(pharmacien?.nom)}`.trim();
  const corps = c.type_candidature === 'instantanee'
    ? `C-Direct: ${qui} accepte ${k.numero_reference} du ${dateCourte(k.date_contrat)} au tarif affiche. ` +
      `Confirmez en 1 clic: c-direct.ca/p/${k.numero_reference}`
    : `C-Direct: Nouvelle candidature de ${qui} pour ${k.numero_reference} du ${dateCourte(k.date_contrat)} ` +
      `a ${Math.round(c.tarif_propose ?? k.tarif_horaire)}$/h. Repondre: c-direct.ca/p/${k.numero_reference}`;

  const res = await envoyerEtLogger(env, {
    vers: pharmacie.telephone, corps,
    type: c.type_candidature === 'instantanee' ? 'candidature_instantanee' : 'candidature_nouvelle',
    profile_id: pharmacie.id, contrat_id: k.id,
  });
  return json({ ok: res.ok });
}

/* ---- candidatures UPDATE (changement de statut) ---- */
async function candidatureMaj(env, c, avant) {
  if (!avant.statut || c.statut === avant.statut)
    return json({ ok: true, ignore: 'Pas de changement de statut' });
  if (await dejaTraite(env, `candidatures:UPDATE:${c.id}:${c.statut}`))
    return json({ ok: true, ignore: 'Doublon' });

  const k = await chargerContrat(env, c.contrat_id);
  if (!k) return json({ ok: true, ignore: 'Contrat introuvable' });

  /* → CONTRE-OFFRE : au pharmacien */
  if (c.statut === 'contre_offre') {
    const pharmacien = await chargerProfil(env, c.pharmacien_id);
    if (!pharmacien?.telephone || pharmacien.sms_optin === false)
      return json({ ok: true, ignore: 'Pharmacien injoignable/optout' });
    const horaireModifie = c.heure_debut_proposee &&
      (c.heure_debut_proposee !== avant.heure_debut_proposee || c.heure_fin_proposee !== avant.heure_fin_proposee);
    const corps = `C-Direct: Contre-offre pour ${k.numero_reference}: ${Math.round(c.tarif_propose)}$/h` +
      (horaireModifie ? `, horaire ${hhmm(c.heure_debut_proposee)}-${hhmm(c.heure_fin_proposee)}` : '') +
      `. Repondre: c-direct.ca/c/${k.numero_reference}`;
    const res = await envoyerAuPharmacien(env, {
      profile_id: pharmacien.id, contrat_id: k.id, vers: pharmacien.telephone,
      corps, type: 'contre_offre',
    });
    return json({ ok: res.ok });
  }

  /* → ACCEPTE : félicitations au pharmacien + info pharmacie
     (les autres candidats reçoivent leur message via LEUR évènement
      refuse automatique — voir plus bas) */
  if (c.statut === 'accepte') {
    const [pharmacien, pharmacie] = await Promise.all([
      chargerProfil(env, c.pharmacien_id), chargerProfil(env, k.pharmacie_id),
    ]);
    const tarif = Math.round(c.tarif_propose ?? k.tarif_horaire);
    const resultats = {};

    if (pharmacien?.telephone && pharmacien.sms_optin !== false) {
      const corps = `C-Direct: Felicitations! ${k.numero_reference} du ${dateCourte(k.date_contrat)} ` +
        `a ${String(pharmacie?.ville || '').slice(0, 20) || 'la pharmacie'} ACCEPTE a ${tarif}$/h. ` +
        `Details: c-direct.ca/c/${k.numero_reference}`;
      resultats.pharmacien = (await envoyerAuPharmacien(env, {
        profile_id: pharmacien.id, contrat_id: k.id, vers: pharmacien.telephone,
        corps, type: 'accepte_pharmacien',
      })).ok;
    }
    if (pharmacie?.telephone) {
      const corps = `C-Direct: Contrat ${k.numero_reference} attribue a ` +
        `${pharmacien?.prenom || ''} ${pharmacien?.nom || ''}`.trim() + '.';
      resultats.pharmacie = (await envoyerEtLogger(env, {
        vers: pharmacie.telephone, corps, type: 'accepte_pharmacie',
        profile_id: pharmacie.id, contrat_id: k.id,
      })).ok;
    }
    /* Courriel « contrat confirmé » + PDF joint aux DEUX parties (langue
       de chacun). Isolé : ne doit JAMAIS casser l'envoi SMS ci-dessus.
       Ne s'exécute que si RESEND_API_KEY est présent (sinon ignoré). */
    try {
      resultats.confirmation = await envoyerConfirmationContrat(env, k, c);
    } catch (e) {
      console.error('confirmation contrat (courriel/PDF):', e);
      resultats.confirmation = { ok: false, erreur: String(e) };
    }
    return json({ ok: true, ...resultats });
  }

  /* → REFUSE automatique (contrat attribué à un autre) : à ce candidat.
     Les refus manuels et les désistements ne génèrent AUCUN SMS. */
  if (c.statut === 'refuse') {
    let dernier = null;
    try { const j = JSON.parse(c.message); dernier = Array.isArray(j) ? j[j.length - 1] : null; } catch (e) {}
    if (!dernier || dernier.auto !== true || dernier.etape !== 'refuse')
      return json({ ok: true, ignore: 'Refus manuel/désistement — pas de SMS' });
    const pharmacien = await chargerProfil(env, c.pharmacien_id);
    if (!pharmacien?.telephone || pharmacien.sms_optin === false)
      return json({ ok: true, ignore: 'Pharmacien injoignable/optout' });
    const corps = `C-Direct: ${k.numero_reference} du ${dateCourte(k.date_contrat)} a ete attribue. ` +
      `D'autres contrats: c-direct.ca`;
    const res = await envoyerAuPharmacien(env, {
      profile_id: pharmacien.id, contrat_id: k.id, vers: pharmacien.telephone,
      corps, type: 'attribue_autres',
    });
    return json({ ok: res.ok });
  }

  return json({ ok: true, ignore: `Statut ${c.statut} sans SMS` });
}

/* ---- contrats UPDATE : annulation (et republication au commit 4) ---- */
async function evenementContrat(env, k, avant) {
  /* ANNULATION d'un contrat attribué (protection du réseau) */
  if (avant.statut === 'attribue' && k.statut === 'annule') {
    if (await dejaTraite(env, `contrats:UPDATE:${k.id}:annule`))
      return json({ ok: true, ignore: 'Doublon' });

    /* candidature retenue + facture de pénalité éventuelle */
    const cands = await sbSelect(env,
      `candidatures?select=id,pharmacien_id,message,heure_debut_proposee,heure_fin_proposee,tarif_propose&contrat_id=eq.${k.id}&statut=eq.accepte&limit=1`);
    const c = cands[0];
    if (!c) return json({ ok: true, ignore: 'Aucune candidature retenue' });

    let pct = 0;
    try {
      const j = JSON.parse(c.message);
      const jalon = Array.isArray(j) ? [...j].reverse().find(x => x.etape === 'annule' && x.par === 'pharmacie') : null;
      pct = jalon ? (parseInt(jalon.penalite_pct) || 0) : 0;
    } catch (e) {}

    const factures = await sbSelect(env,
      `factures?select=numero_facture,total&candidature_id=eq.${c.id}&type_facture=eq.penalite_annulation&limit=1`);
    const facture = factures[0];

    const [pharmacien, pharmacie, regles] = await Promise.all([
      chargerProfil(env, c.pharmacien_id), chargerProfil(env, k.pharmacie_id),
      sbSelect(env, 'regles_reseau?select=penalite_annulation_48h_pct&id=eq.1').then(l => l[0] || {}),
    ]);
    const resultats = {};

    if (facture && pct > 0) {
      const montant = Math.round(parseFloat(facture.total) || 0);
      const delai = pct >= (parseInt(regles.penalite_annulation_48h_pct) || 100) ? '48h' : '7 jours';
      if (pharmacien?.telephone && pharmacien.sms_optin !== false) {
        resultats.pharmacien = (await envoyerAuPharmacien(env, {
          profile_id: pharmacien.id, contrat_id: k.id, vers: pharmacien.telephone,
          corps: `C-Direct: ${k.numero_reference} annule a moins de ${delai}. Facture de ${pct}% (${montant}$) ` +
                 `emise automatiquement en votre faveur (regles du reseau).`,
          type: 'annulation_pharmacien',
        })).ok;
      }
      if (pharmacie?.telephone) {
        resultats.pharmacie = (await envoyerEtLogger(env, {
          vers: pharmacie.telephone,
          corps: `C-Direct: Annulation ${k.numero_reference}: facture de ${montant}$ ` +
                 `conformement aux regles acceptees a la publication.`,
          type: 'annulation_pharmacie', profile_id: pharmacie.id, contrat_id: k.id,
        })).ok;
      }
    } else if (pharmacien?.telephone && pharmacien.sms_optin !== false) {
      /* hors fenêtre : informer simplement le pharmacien */
      resultats.pharmacien = (await envoyerAuPharmacien(env, {
        profile_id: pharmacien.id, contrat_id: k.id, vers: pharmacien.telephone,
        corps: `C-Direct: ${k.numero_reference} du ${dateCourte(k.date_contrat)} annule par la pharmacie ` +
               `(aucune penalite - hors fenetre). D'autres contrats: c-direct.ca`,
        type: 'annulation_pharmacien',
      })).ok;
    }
    return json({ ok: true, penalite_pct: pct, ...resultats });
  }

  /* REPUBLICATION sur hausse de tarif — UNIQUEMENT quand une pharmacie
     augmente tarif_horaire d'un contrat encore 'ouvert'. Aucune autre
     modification ne déclenche de re-diffusion. Liste RÉÉVALUÉE (le
     nouveau tarif peut débloquer des pharmaciens filtrés avant). */
  if (avant.statut === 'ouvert' && k.statut === 'ouvert' &&
      avant.tarif_horaire != null &&
      parseFloat(k.tarif_horaire) > parseFloat(avant.tarif_horaire)) {
    if (await dejaTraite(env, `contrats:UPDATE:${k.id}:tarif:${k.tarif_horaire}`))
      return json({ ok: true, ignore: 'Doublon' });

    const nouveau = Math.round(k.tarif_horaire);
    const delta = Math.round((parseFloat(k.tarif_horaire) - parseFloat(avant.tarif_horaire)) * 100) / 100;
    const cibles = await ciblesFiltrees(env, k);
    const ville = String(cibles.pharmacie.ville || 'Quebec').slice(0, 20);
    const corps = `C-Direct: ${k.numero_reference} republie: ${nouveau}$/h (+${delta}$) - ${ville}, ` +
                  `${dateCourte(k.date_contrat)}. Postulez: c-direct.ca/c/${k.numero_reference}`;

    const envoiPrevu = ajusterEnvoi(new Date(Date.now() + 5 * 60 * 1000)).toISOString();
    await enfilerSms(env, cibles.retenus.map(r => ({
      profile_id: r.p.id, contrat_id: k.id, pharmacie_id: k.pharmacie_id,
      to_number: r.p.telephone, type: 'contrat_republie', corps, ville,
      envoyer_apres: envoiPrevu,
    })));
    return json({ ok: true, republie: true, retenus: cibles.retenus.length, filtres: cibles.nFiltres });
  }

  return json({ ok: true, ignore: 'UPDATE contrats sans SMS' });
}

/* ---- factures UPDATE : passage en retard → 1re relance polie ---- */
async function factureMaj(env, f, avant) {
  if (!(f.statut === 'en_retard' && avant.statut !== 'en_retard'))
    return json({ ok: true, ignore: 'Changement sans SMS' });
  if (await dejaTraite(env, `factures:UPDATE:${f.id}:en_retard`))
    return json({ ok: true, ignore: 'Doublon' });
  const res = await relancerFacture(env, f);
  return json(res);
}

/* relance d'une facture en retard (webhook = 1re, cron = suivantes) */
async function relancerFacture(env, f) {
  const cands = await sbSelect(env,
    `candidatures?select=id,pharmacien_id,contrat_id&id=eq.${f.candidature_id}`);
  const c = cands[0];
  if (!c) return { ok: true, ignore: 'Candidature introuvable' };
  const k = await chargerContrat(env, c.contrat_id);
  const [pharmacien, pharmacie] = await Promise.all([
    chargerProfil(env, c.pharmacien_id), chargerProfil(env, k.pharmacie_id),
  ]);
  if (!pharmacie?.telephone) return { ok: true, ignore: 'Pharmacie sans téléphone' };

  const numero = 'F-' + String(f.numero_facture).padStart(6, '0');
  const montant = Math.round(parseFloat(f.total) || 0);
  const corps = `C-Direct: Rappel - facture ${numero} de ${pharmacien?.prenom || ''} ${pharmacien?.nom || ''}`.trim() +
    ` (${montant}$) echue le ${dateCourte(f.date_echeance)}. Merci de proceder au paiement.`;
  const res = await envoyerEtLogger(env, {
    vers: pharmacie.telephone, corps, type: 'rappel_paiement',
    profile_id: pharmacie.id, contrat_id: c.contrat_id,
  });
  return { ok: res.ok, facture: numero };
}

/* =====================================================================
   POST /twilio-inbound — SMS entrants (webhook du numéro Twilio).
   Twilio poste en application/x-www-form-urlencoded : From, Body, …
   · ARRET / STOP / UNSUBSCRIBE / DESABONNER (+ variantes accentuées)
     → profiles.sms_optin = false pour ce numéro E.164 + journal.
     (Twilio bloque déjà ARRET/STOP côté opérateur sur les longs codes
      canadiens — ici on synchronise NOTRE base en plus.)
   · Tout autre message : journalisé pour lecture admin, AUCUNE réponse.
===================================================================== */
const MOTS_OPTOUT = ['ARRET', 'ARRÊT', 'STOP', 'UNSUBSCRIBE', 'DESABONNER', 'DÉSABONNER', 'STOPALL'];

async function routeTwilioInbound(request, env) {
  const form = await request.formData().catch(() => null);
  const de = form ? String(form.get('From') || '') : '';
  const corps = form ? String(form.get('Body') || '') : '';
  const sid = form ? String(form.get('MessageSid') || '') : null;

  /* réponse TwiML vide = aucune réponse automatique */
  const twimlVide = new Response('<?xml version="1.0" encoding="UTF-8"?><Response></Response>',
    { headers: { 'Content-Type': 'text/xml' } });

  if (!de) return twimlVide;

  const premierMot = corps.trim().toUpperCase().split(/\s+/)[0] || '';
  const estOptout = MOTS_OPTOUT.includes(premierMot);

  /* profil correspondant à ce numéro (peut être absent) */
  const profils = await sbSelect(env,
    `profiles?select=id,sms_optin&telephone=eq.${encodeURIComponent(de)}&limit=1`);
  const profil = profils[0] || null;

  if (estOptout) {
    if (profil) {
      await sbUpdate(env, `profiles?id=eq.${profil.id}`, { sms_optin: false, sms_optin_date: null });
    }
    await loggerSms(env, {
      profile_id: profil ? profil.id : null,
      type: 'optout',
      to_number: de,
      body: corps.slice(0, 300),
      twilio_sid: sid,
      statut: profil ? 'optout_applique' : 'optout_numero_inconnu',
    });
  } else {
    await loggerSms(env, {
      profile_id: profil ? profil.id : null,
      type: 'inbound',
      to_number: de,
      body: corps.slice(0, 300),
      twilio_sid: sid,
      statut: 'recu',
    });
  }

  return twimlVide;
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
