// =====================================================================
// TRAJET.JS — C-Direct · fonction "Trajet"
// « Est-ce que je peux m'y rendre et rentrer en sécurité — et à quelle
// heure dois-je partir ? » Aide à la décision avant d'accepter un quart
// d'hiver, à partir des prévisions météo réelles (Open-Meteo) pour
// l'aller ET le retour du pharmacien vers la pharmacie.
//
// Charger APRÈS auth.js + fsa-qc.js. Ne fait JAMAIS d'appel météo direct
// depuis le navigateur — passe toujours par /api/meteo (Cloudflare Pages
// Function, cache serveur dans Supabase, voir functions/api/meteo.js et
// sql/58-trajet-meteo.sql).
//
// deriveWindows()/classifyRisk() ci-dessous sont un PORT VERBATIM de la
// logique validée dans le prototype c-direct-trajet-v2.html — ne pas
// modifier sans revalider contre le prototype.
// =====================================================================
(function(){

/* ---- temps de route estimé à partir du km (aucune API payante — même
   esprit que fsa-qc.js : distance à vol d'oiseau, pas un vrai routage).
   Vitesse moyenne mixte route régionale/ville. ---- */
const CD_VITESSE_MOY_KMH = 65;
window.cdDriveMinEstime = function(km){
  if(km == null || isNaN(km)) return null;
  return Math.max(10, Math.round(km / CD_VITESSE_MOY_KMH * 60));
};

function hmVersMin(h){
  const s = String(h||'').slice(0,5);
  const m = s.match(/^(\d{1,2}):(\d{2})/);
  if(!m) return null;
  return parseInt(m[1],10)*60 + parseInt(m[2],10);
}
function fmtHM(min){
  const total = ((Math.round(min)%1440)+1440)%1440;
  return Math.floor(total/60) + ' h ' + String(total%60).padStart(2,'0');
}

/* ---- fenêtres de trajet (aller/retour) — PORT VERBATIM du prototype ---- */
window.cdDeriveWindows = function(s){
  const BUFFER = 15; // min de battement avant le départ
  const leave = s.startMin - s.driveMin - BUFFER;
  return {
    aller:  { from: leave - 30, to: s.startMin, leaveMin: leave },
    retour: { from: s.endMin, to: s.endMin + s.driveMin }
  };
};

/* ---- classification du risque : pire des deux fenêtres — PORT VERBATIM ---- */
window.cdClassifyRisk = function(s, win){
  const worst = (w) => {
    const hrs = s.hourly.filter(h => h.min >= w.from && h.min <= w.to);
    let ice=false, snow=0, wind=0;
    for(const h of hrs){ if(h.type==='ice') ice=true; snow+=h.cm||0; wind=Math.max(wind,h.wind||0); }
    if (ice || snow > 10) return 'hazard';
    if (snow >= 2  || wind >= 40) return 'watch';
    return 'clear';
  };
  const a = worst(win.aller), r = worst(win.retour);
  const rank = { clear:0, watch:1, hazard:2 };
  let overall = rank[a] >= rank[r] ? a : r;
  if (s.alertWarning) overall = 'hazard';
  return { overall, aller:a, retour:r, affected: rank[r] > rank[a] ? 'retour' : 'aller' };
};

/* ---- fenêtre d'affichage ~7 jours (aligné sur /api/meteo forecast_days=7).
   Au-delà : on n'affiche RIEN, jamais de donnée inventée. ---- */
window.cdDansFenetreTrajet = function(dateISO){
  if(!dateISO) return false;
  const j = Math.round((new Date(String(dateISO).slice(0,10)+'T12:00:00') - new Date(new Date().toISOString().slice(0,10)+'T12:00:00')) / 86400000);
  return j >= 0 && j <= 7;
};

/* ---- cache météo serveur — un ou plusieurs FSA/codes postaux en un appel ---- */
window.cdMeteoFsa = async function(fsaOuListe){
  const arr = Array.isArray(fsaOuListe) ? fsaOuListe : [fsaOuListe];
  const uniq = [...new Set(arr.map(f => (typeof cdFsa === 'function' ? (cdFsa(f) || f) : f)).filter(Boolean))];
  if(!uniq.length) return {};
  try{
    const r = await fetch('/api/meteo?fsa=' + encodeURIComponent(uniq.join(',')));
    if(!r.ok) return {};
    return await r.json();
  }catch(e){ return {}; }
};

/* ---- calcule le Trajet pour UN contrat, ou null si non calculable
   (hors fenêtre ~7 jours, code postal / distance manquants, pas de
   donnée météo pour ce FSA ce jour-là). Ne jamais afficher sans données
   réelles.
     k          : ligne contrat (date_contrat, heure_debut, heure_fin, code_postal)
     distanceKm : déjà calculée par l'appelant (cdDistanceKm, aller simple)
     meteoParFsa: résultat de cdMeteoFsa() → { [fsa]: {horaire, alerte, maj_le} } ---- */
window.cdTrajetPourContrat = function(k, distanceKm, meteoParFsa){
  try{
    if(!k || !k.date_contrat || !k.code_postal) return null;
    if(!cdDansFenetreTrajet(k.date_contrat)) return null;
    if(distanceKm == null || typeof cdFsa !== 'function') return null;
    const fsa = cdFsa(k.code_postal);
    const meteo = fsa && meteoParFsa ? meteoParFsa[fsa] : null;
    if(!meteo || !meteo.horaire) return null;
    const hourly = meteo.horaire[String(k.date_contrat).slice(0,10)];
    if(!hourly || !hourly.length) return null;
    const startMin = hmVersMin(k.heure_debut), endMin = hmVersMin(k.heure_fin);
    const driveMin = cdDriveMinEstime(distanceKm);
    if(startMin==null || endMin==null || driveMin==null) return null;

    const shift = { startMin, endMin, driveMin, hourly, alertWarning: !!meteo.alerte };
    const win = cdDeriveWindows(shift);
    const risk = cdClassifyRisk(shift, win);
    return { win, risk, shift, alerte: meteo.alerte || null };
  }catch(e){ return null; }
};

/* ---- pastille compacte pour une liste dense — seulement vigilance/risque
   (comme .flag-indispo, on ne surcharge pas chaque ligne d'un « dégagé »). ---- */
window.cdTrajetPastilleHTML = function(trajet){
  if(!trajet || trajet.risk.overall === 'clear') return '';
  const hazard = trajet.risk.overall === 'hazard';
  const coul = hazard ? 'var(--rouge)' : 'var(--jaune)';
  const bg   = hazard ? 'rgba(192,57,43,.1)' : 'rgba(232,184,73,.1)';
  const bord = hazard ? 'rgba(192,57,43,.4)' : 'rgba(232,184,73,.4)';
  const texte = (hazard ? '\u{1F9CA} Route — risque élevé' : '❄️ Route — vigilance');
  return '<div style="display:inline-block;margin-top:4px;font-family:\'IBM Plex Mono\',monospace;'
    + 'font-weight:400;font-size:10px;letter-spacing:.04em;padding:1px 7px;border-radius:99px;'
    + 'border:1px solid ' + bord + ';background:' + bg + ';color:' + coul + '" '
    + 'title="Fonction Trajet — estimation météo pour votre aller-retour">' + texte + '</div>';
};

function libelleEtat(e){ return e==='hazard' ? 'Risque élevé' : (e==='watch' ? 'Vigilance' : 'Dégagé'); }
function couleurEtat(e){ return e==='hazard' ? 'var(--rouge)' : (e==='watch' ? 'var(--jaune)' : 'var(--vert-vif)'); }

function texteEntete(trajet){
  const { risk } = trajet;
  if(risk.overall==='clear') return { titre:'Route dégagée pour l’aller et le retour', sous:'Aucune précipitation notable attendue sur vos deux trajets.' };
  const w = risk.affected === 'retour' ? 'retour' : 'aller';
  const fen = risk.affected==='retour' ? trajet.win.retour : trajet.win.aller;
  const heures = trajet.shift.hourly.filter(h => h.min>=fen.from && h.min<=fen.to);
  const ice = heures.some(h=>h.type==='ice');
  const cm = Math.round(heures.reduce((t,h)=>t+(h.cm||0),0)*10)/10;
  if(ice) return {
    titre: 'Verglas prévu sur votre ' + w,
    sous: risk.overall==='hazard' ? 'Partez tôt ou discutez d’un décalage avec la pharmacie.' : 'Restez prudent(e) sur la route.'
  };
  if(cm > 0) return {
    titre: cm + ' cm de neige prévus sur votre ' + w,
    sous: risk.overall==='hazard' ? 'Accumulation importante — prévoyez large.' : 'Prévoyez quelques minutes de plus.'
  };
  return { titre:'Vent fort prévu sur votre ' + w, sous:'Conditions de conduite plus difficiles que la normale.' };
}

/* ---- mini ligne du temps (barres neige/verglas 5h-21h + repères aller/retour) ---- */
function miniTimelineHTML(trajet){
  const H0=5*60, H1=21*60, SPAN=H1-H0;
  const pct = m => Math.max(0, Math.min(100, (m-H0)/SPAN*100));
  const parHeure = new Map(trajet.shift.hourly.map(h=>[Math.round(h.min/60)*60, h]));
  const barres = [];
  for(let m=H0; m<=H1; m+=60){
    const h = parHeure.get(m);
    const on = !!(h && h.type!=='none');
    const glace = !!(h && h.type==='ice');
    const inten = h ? (glace ? 0.65 : Math.min(1,(h.cm||0)/3)) : 0;
    const ht = on ? Math.round(10 + inten*30) : 2;
    const coul = glace ? 'rgba(192,57,43,' : (on ? 'rgba(11,110,79,' : 'rgba(90,107,99,');
    const op = on ? (0.35 + inten*0.55).toFixed(2) : '0.12';
    barres.push('<div style="flex:1;border-radius:2px 2px 0 0;height:'+ht+'px;background:'+coul+op+')"></div>');
  }
  // étiquettes Aller/Retour dans leur PROPRE rangée au-dessus du graphique
  // (jamais superposées aux repères d'heure 6h/9h/12h.../21h en bas — un
  // ancien essai les mettait sous le graphique et elles se chevauchaient).
  const etiquette = (min, coul, label) => '<span style="position:absolute;left:'+pct(min)+'%;transform:translateX(-50%);top:0;font-size:9px;font-weight:700;color:'+coul+';white-space:nowrap">'+label+'</span>';
  const trait = (min, coul) => '<div style="position:absolute;left:'+pct(min)+'%;top:0;bottom:16px;width:2px;background:'+coul+'"></div>';
  const axe = [6,9,12,15,18,21].map(h=>'<span style="position:absolute;left:'+pct(h*60)+'%;transform:translateX(-50%);font-size:9px;color:var(--sourd)">'+h+' h</span>').join('');
  return '<div style="background:var(--panneau2);border:1px solid var(--ligne2);border-radius:8px;padding:12px 12px 10px;margin:10px 0">'
    + '<div style="font-family:\'IBM Plex Mono\',monospace;font-size:9.5px;letter-spacing:.1em;text-transform:uppercase;color:var(--sourd);margin-bottom:10px">Précipitations sur la journée</div>'
    + '<div style="position:relative;height:13px;margin-bottom:3px">'
    +   etiquette(trajet.win.aller.leaveMin, couleurEtat(trajet.risk.aller), 'Aller ' + fmtHM(trajet.win.aller.leaveMin))
    +   etiquette(trajet.win.retour.from, couleurEtat(trajet.risk.retour), 'Retour ' + fmtHM(trajet.win.retour.from))
    + '</div>'
    + '<div style="position:relative;height:46px">'
    +   '<div style="position:absolute;left:0;right:0;bottom:16px;top:0;display:flex;align-items:flex-end;gap:2px">' + barres.join('') + '</div>'
    +   trait(trajet.win.aller.leaveMin, couleurEtat(trajet.risk.aller))
    +   trait(trajet.win.retour.from, couleurEtat(trajet.risk.retour))
    +   '<div style="position:absolute;left:0;right:0;bottom:0;height:14px;border-top:1px solid var(--ligne2)">' + axe + '</div>'
    + '</div></div>';
}

/* ---- bloc complet pour la fiche contrat (contrat.html) — headline + mini
   ligne du temps + résumé aller/retour. Rien n'est affiché si trajet===null,
   l'appelant doit garder le bloc caché dans ce cas. ---- */
window.cdTrajetBlocHTML = function(trajet){
  if(!trajet) return '';
  const { risk, win } = trajet;
  const txt = texteEntete(trajet);
  const ligneFenetre = (label, w, etat) => '<div style="display:flex;justify-content:space-between;gap:10px;padding:7px 0;font-size:13px;border-top:1px solid var(--ligne2)">'
    + '<span style="color:var(--sourd)">' + label + ' · ' + fmtHM(w.from) + '–' + fmtHM(w.to) + '</span>'
    + '<b style="color:' + couleurEtat(etat) + '">' + libelleEtat(etat) + '</b></div>';
  return '<div style="background:var(--panneau2);border:1px solid var(--ligne2);border-radius:8px;padding:14px 16px">'
    + '<div style="font-weight:700;font-size:15px;color:' + couleurEtat(risk.overall) + '">' + txt.titre + '</div>'
    + '<div style="color:var(--sourd);font-size:12.5px;margin-top:3px">' + txt.sous + '</div>'
    + miniTimelineHTML(trajet)
    + ligneFenetre('Aller', win.aller, risk.aller)
    + ligneFenetre('Retour', win.retour, risk.retour)
    + '<div style="font-size:10.5px;color:var(--sourd);margin-top:10px;line-height:1.5">Estimé à partir des prévisions Open-Meteo pour votre trajet (temps de route estimé à ' + CD_VITESSE_MOY_KMH + ' km/h de moyenne — pas un calcul d’itinéraire réel). Visible seulement dans les ~7 jours à venir.</div>'
    + '</div>';
};

})();
