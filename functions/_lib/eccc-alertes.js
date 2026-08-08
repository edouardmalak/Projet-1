/* =====================================================================
   ECCC-ALERTES.JS — alertes météo officielles d'Environnement Canada,
   pour la fonction Trajet (voir /trajet.js, functions/api/meteo.js).

   Source : MSC Datamart, flux public CAP-XML, aucune clé requise :
     https://dd.weather.gc.ca/today/alerts/cap/{AAAAMMJJ}/{bureau}/{hh}/
   Bureau responsable pour tout le Québec : CWUL (Centre de prévision des
   intempéries du Québec, Montréal). Confirmé EN DIRECT le 2026-08-08 —
   contrairement à une première tentative (GeoMet-OGC-API, aucune
   collection "alerts" utilisable trouvée), ce flux Datamart est réel :
   un fichier réel avec une alerte "orages" active (zones Rouyn/Malartic/
   Val-d'Or) a été trouvé, téléchargé et analysé pour construire ce code.

   Best-effort à chaque étage : réseau, format de dossier, format XML —
   n'importe laquelle peut échouer sans jamais faire tomber /api/meteo.
   Au pire, aucune alerte n'est trouvée (jamais de donnée inventée), et
   la fonction Trajet continue de fonctionner sur les seuils Open-Meteo
   (neige/verglas/vent) qui sont son signal principal de toute façon.
   ===================================================================== */

const BASE = 'https://dd.weather.gc.ca/today/alerts/cap';
const BUREAU_QC = 'CWUL';

// Aléas pertinents pour un trajet routier d'hiver. Volontairement large
// (mieux vaut remonter une alerte qui s'avère peu grave que d'en rater
// une vraie) mais borné aux aléas hivernaux — pas de chaleur/UV/qualité
// de l'air, sans rapport avec la fonction Trajet.
const MOTS_HIVER = /verglas|neige|blizzard|poudrerie|tempête hivernale|refroidissement éolien|froid extrême|froid intense|\bglace\b/i;

function extraire(txt, nom) {
  const m = txt.match(new RegExp('<' + nom + '>([\\s\\S]*?)</' + nom + '>'));
  return m ? m[1].trim() : null;
}
function extraireTous(txt, nom) {
  const re = new RegExp('<' + nom + '>([\\s\\S]*?)</' + nom + '>', 'g');
  const out = []; let m;
  while ((m = re.exec(txt))) out.push(m[1]);
  return out;
}
/* "48.4498,-78.4996 47.8372,-78.25 ..." -> [[lat,lng], ...] */
function analyserPolygone(txt) {
  return txt.trim().split(/\s+/)
    .map(p => p.split(',').map(Number))
    .filter(p => p.length === 2 && !isNaN(p[0]) && !isNaN(p[1]));
}
/* point-en-polygone, ray casting standard — poly: [[lat,lng], ...] */
function dansPolygone(lat, lng, poly) {
  let dedans = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const yi = poly[i][0], xi = poly[i][1], yj = poly[j][0], xj = poly[j][1];
    const traverse = ((yi > lat) !== (yj > lat)) && (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi);
    if (traverse) dedans = !dedans;
  }
  return dedans;
}
async function texteUrl(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error('http ' + r.status + ' ' + url);
  return r.text();
}
/* sous-dossiers "hh/" d'un dossier jour, du plus récent au plus ancien */
async function listerHeures(jourUrl) {
  const html = await texteUrl(jourUrl);
  const heures = [...html.matchAll(/href="(\d{2})\/"/g)].map(m => m[1]);
  return [...new Set(heures)].sort().reverse();
}
/* fichiers .cap d'un dossier heure */
async function listerFichiers(heureUrl) {
  const html = await texteUrl(heureUrl);
  return [...html.matchAll(/href="([^"?]+\.cap)"/g)].map(m => m[1]);
}

/* Construit la liste des zones actuellement en alerte hivernale (Québec,
   bureau CWUL) à partir des fichiers CAP les plus récents disponibles.
   Renvoie [{areaDesc, polygones, titre, source, expires}] — jamais
   d'exception, au pire un tableau vide. */
async function zonesAlerteHivernale() {
  try {
    const auj = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    const hier = new Date(Date.now() - 86400000).toISOString().slice(0, 10).replace(/-/g, '');

    let jour = auj, heures = [];
    try { heures = await listerHeures(`${BASE}/${auj}/${BUREAU_QC}/`); } catch (e) { heures = []; }
    if (!heures.length) {
      jour = hier;
      try { heures = await listerHeures(`${BASE}/${hier}/${BUREAU_QC}/`); } catch (e) { heures = []; }
    }
    if (!heures.length) return [];

    const heuresRecentes = heures.slice(0, 2);
    const listesFichiers = await Promise.all(
      heuresRecentes.map(h => listerFichiers(`${BASE}/${jour}/${BUREAU_QC}/${h}/`).catch(() => []))
    );
    const urls = [];
    heuresRecentes.forEach((h, i) => {
      (listesFichiers[i] || []).slice(-2).forEach(n => urls.push(`${BASE}/${jour}/${BUREAU_QC}/${h}/${n}`));
    });
    if (!urls.length) return [];

    const documents = await Promise.all(urls.slice(0, 4).map(u => texteUrl(u).catch(() => null)));

    const zones = [];
    for (const xml of documents) {
      if (!xml) continue;
      try {
        const statut = extraire(xml, 'status');
        const typeMsg = extraire(xml, 'msgType');
        if (statut !== 'Actual' || typeMsg === 'Cancel') continue;
        const source = extraire(xml, 'source') || 'Environnement Canada';
        for (const info of extraireTous(xml, 'info')) {
          const langue = (extraire(info, 'language') || '').toLowerCase();
          if (!langue.startsWith('fr')) continue;
          const evenement = extraire(info, 'event') || '';
          if (!MOTS_HIVER.test(evenement)) continue;
          const expireTxt = extraire(info, 'expires');
          const expireMs = expireTxt ? Date.parse(expireTxt) : NaN;
          if (!isNaN(expireMs) && expireMs < Date.now()) continue; // déjà expirée
          const titre = extraire(info, 'headline') || evenement;
          for (const area of extraireTous(info, 'area')) {
            const areaDesc = extraire(area, 'areaDesc');
            const polygones = extraireTous(area, 'polygon').map(analyserPolygone).filter(p => p.length >= 3);
            if (areaDesc && polygones.length) zones.push({ areaDesc, polygones, titre, source, expires: expireTxt || null });
          }
        }
      } catch (e) { /* un document mal formé n'affecte pas les autres */ }
    }
    return zones;
  } catch (e) {
    return []; // best-effort total : jamais d'exception vers l'appelant
  }
}

/* alerte applicable à un point (lat,lng) donné parmi les zones trouvées, ou null */
function trouverAlertePourPoint(zones, lat, lng) {
  for (const z of zones) {
    for (const poly of z.polygones) {
      if (dansPolygone(lat, lng, poly)) {
        return { t: z.titre, s: z.areaDesc + ' · ' + z.source, expires: z.expires };
      }
    }
  }
  return null;
}

export { zonesAlerteHivernale, trouverAlertePourPoint };
