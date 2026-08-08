/* =====================================================================
   C-DIRECT · /api/meteo — Cloudflare Pages Function
   ---------------------------------------------------------------------
   Sert la fonction "Trajet" (voir /trajet.js) : horaire météo (Open-
   Meteo, gratuit, sans clé) pour un ou plusieurs FSA québécois, mis en
   cache dans Supabase (table public.meteo_cache, sql/58) pour ne JAMAIS
   appeler Open-Meteo à chaque chargement de page — seulement quand le
   cache d'un FSA a plus de FRESH_MS.

   Appel : GET /api/meteo?fsa=H1B,J4B,G1V
   Réponse : { "H1B": { horaire, alerte, maj_le }, "J4B": {...}, ... }
   Un FSA absent de la réponse = aucune donnée fiable disponible (le
   client doit alors simplement ne rien afficher — jamais de donnée
   inventée).

   Alertes ECCC officielles : DIFFÉRÉ. Aucun endpoint public gratuit
   fiable confirmé en direct (voir A-FAIRE-CONSOLIDE.md) — `alerte` reste
   toujours null pour l'instant. classifyRisk() gère déjà ce cas (le
   badge se base uniquement sur les seuils neige/verglas/vent calculés
   depuis Open-Meteo, qui couvrent l'essentiel du signal).

   Clé Supabase utilisée : la clé "publishable" (anon) — la même que
   dans supabase-config.js, déjà publique côté client. La sécurité de
   l'écriture repose sur les politiques RLS de meteo_cache (bornées à un
   format de FSA valide), pas sur le secret de cette clé.
   ===================================================================== */

import { FSA_CENTROIDES } from '../_lib/fsa-centroides.js';

const SB_URL = 'https://fenlujjozanerbzyypjt.supabase.co';
const SB_KEY = 'sb_publishable_gl9B3gY9gHX2iG_aaPoJZw_N4-qePHn';

const FRESH_MS = 3 * 60 * 60 * 1000; // 3 h — un horaire météo n'a pas besoin d'être plus frais que ça ici
const MAX_FSA_PAR_APPEL = 25;
const RE_FSA = /^[GHJ][0-9][A-Z]$/;
const CODES_VERGLAS = new Set([56, 57, 66, 67]); // WMO : bruine/pluie verglaçante

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'public, max-age=600', // cache d'arête Cloudflare — le vrai cache est côté Supabase
    },
  });
}

async function sb(path, init) {
  const r = await fetch(SB_URL + '/rest/v1/' + path, {
    ...init,
    headers: {
      apikey: SB_KEY,
      authorization: 'Bearer ' + SB_KEY,
      'content-type': 'application/json',
      ...(init && init.headers),
    },
  });
  return r;
}

/* horaire Open-Meteo -> { "AAAA-MM-JJ": [{min,type,cm,wind,temp}, ...] } */
function traiterHoraireOpenMeteo(h) {
  const horaire = {};
  const n = (h.time || []).length;
  for (let i = 0; i < n; i++) {
    const t = h.time[i]; // "2026-08-10T05:00"
    const dateISO = t.slice(0, 10);
    const hh = parseInt(t.slice(11, 13), 10);
    const mm = parseInt(t.slice(14, 16), 10) || 0;
    const code = h.weather_code ? h.weather_code[i] : null;
    const cm = (h.snowfall ? h.snowfall[i] : 0) || 0;
    const wind = (h.wind_speed_10m ? h.wind_speed_10m[i] : 0) || 0;
    const temp = h.temperature_2m ? h.temperature_2m[i] : null;
    const type = CODES_VERGLAS.has(code) ? 'ice' : (cm > 0 ? 'snow' : 'none');
    (horaire[dateISO] = horaire[dateISO] || []).push({
      min: hh * 60 + mm,
      type,
      cm: Math.round(cm * 10) / 10,
      wind: Math.round(wind),
      temp: temp == null ? null : Math.round(temp * 10) / 10,
    });
  }
  return horaire;
}

async function fetchOpenMeteo(lat, lng) {
  const url = 'https://api.open-meteo.com/v1/forecast'
    + '?latitude=' + lat + '&longitude=' + lng
    + '&hourly=temperature_2m,snowfall,weather_code,wind_speed_10m'
    + '&timezone=America%2FToronto&forecast_days=7';
  const r = await fetch(url);
  if (!r.ok) throw new Error('open-meteo ' + r.status);
  const data = await r.json();
  if (!data || !data.hourly) throw new Error('open-meteo: reponse sans hourly');
  return traiterHoraireOpenMeteo(data.hourly);
}

export async function onRequestGet(context) {
  try {
    const url = new URL(context.request.url);
    const demandes = (url.searchParams.get('fsa') || '')
      .split(',')
      .map(s => s.trim().toUpperCase())
      .filter(s => RE_FSA.test(s));
    const fsas = [...new Set(demandes)].slice(0, MAX_FSA_PAR_APPEL);

    if (!fsas.length) return jsonResponse({});

    // 1) lire le cache existant pour tous les FSA demandés en un seul appel
    const enCache = {};
    try {
      const r = await sb('meteo_cache?fsa=in.(' + fsas.join(',') + ')&select=fsa,horaire,alerte,maj_le');
      if (r.ok) {
        const rows = await r.json();
        rows.forEach(row => { enCache[row.fsa] = row; });
      }
    } catch (e) { /* pas de cache lisible -> on tente quand même un fetch frais plus bas */ }

    const maintenant = Date.now();
    const resultat = {};
    const aRafraichir = [];

    fsas.forEach(fsa => {
      const row = enCache[fsa];
      const frais = row && (maintenant - new Date(row.maj_le).getTime()) < FRESH_MS;
      if (frais) {
        resultat[fsa] = { horaire: row.horaire, alerte: row.alerte, maj_le: row.maj_le };
      } else {
        aRafraichir.push(fsa);
      }
    });

    // 2) rafraîchir les FSA manquants/périmés en parallèle
    if (aRafraichir.length) {
      const lignesAEcrire = [];
      await Promise.all(aRafraichir.map(async fsa => {
        const centre = FSA_CENTROIDES[fsa];
        if (!centre) return; // FSA hors Québec ou inconnu -> silencieusement absent de la réponse
        try {
          const horaire = await fetchOpenMeteo(centre[0], centre[1]);
          const maj_le = new Date().toISOString();
          resultat[fsa] = { horaire, alerte: null, maj_le };
          lignesAEcrire.push({ fsa, lat: centre[0], lng: centre[1], horaire, alerte: null, maj_le });
        } catch (e) {
          // Open-Meteo indisponible : retomber sur le cache périmé plutôt que rien,
          // c'est une vraie donnée (juste pas fraîche) — jamais de donnée inventée.
          const perime = enCache[fsa];
          if (perime) resultat[fsa] = { horaire: perime.horaire, alerte: perime.alerte, maj_le: perime.maj_le };
        }
      }));

      // 3) écrire les lignes fraîches dans Supabase (upsert bornée par RLS — voir sql/58)
      if (lignesAEcrire.length) {
        try {
          await sb('meteo_cache?on_conflict=fsa', {
            method: 'POST',
            headers: { prefer: 'resolution=merge-duplicates,return=minimal' },
            body: JSON.stringify(lignesAEcrire),
          });
        } catch (e) { /* le cache est un bonus de performance — jamais bloquant pour la réponse */ }
      }
    }

    return jsonResponse(resultat);
  } catch (e) {
    // Ne jamais faire planter la page pour une fonctionnalité secondaire.
    return jsonResponse({}, 200);
  }
}
