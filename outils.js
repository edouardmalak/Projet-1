// =====================================================
// OUTILS.JS — helpers C-Direct (journal de négociation)
// Charger après auth.js.
//
// Le schéma étant figé, le fil de négociation est PERSISTÉ
// dans candidatures.message sous forme de journal JSON :
//   [{etape, par, tarif, hd, hf, message, quand}, …]
// etape : candidature | contre_offre | accepte | refuse
// par   : pharmacien | pharmacie
// Les colonnes tarif_propose / heure_*_proposee / statut
// reflètent toujours le DERNIER état (requêtes + RLS).
// =====================================================
(function(){

/* ---- lire le journal (tolère null / ancien texte libre) ---- */
window.cdJalons = function(texte){
  if(!texte) return [];
  try{
    const a = JSON.parse(texte);
    return Array.isArray(a) ? a : [];
  }catch(e){
    // candidature d'avant le journal : texte libre = message initial
    return [{etape:'candidature', par:'pharmacien', message:texte, quand:null}];
  }
};

/* ---- ajouter un jalon, renvoie le texte à sauvegarder ---- */
window.cdJalonAjouter = function(texte, jalon){
  const a = cdJalons(texte);
  jalon.quand = new Date().toISOString();
  a.push(jalon);
  return JSON.stringify(a);
};

/* ---- libellés du fil ---- */
window.cdJalonLibelle = function(j){
  const qui = j.par === 'pharmacie' ? 'Pharmacie' : 'Pharmacien(ne)';
  const libs = {
    candidature: j.type === 'instantanee'
      ? 'Candidature au tarif affiché'
      : 'Offre du pharmacien / de la pharmacienne',
    contre_offre: 'Contre-offre de la pharmacie',
    accepte: 'Entente conclue — acceptée par ' + qui.toLowerCase(),
    refuse: 'Refus — ' + qui.toLowerCase()
  };
  return libs[j.etape] || j.etape;
};

window.cdQuand = function(iso){
  if(!iso) return '';
  return new Date(iso).toLocaleDateString('fr-CA', {month:'short', day:'numeric'}) +
         ' ' + new Date(iso).toLocaleTimeString('fr-CA', {hour:'2-digit', minute:'2-digit'});
};

/* ---- termes d'un jalon en texte ---- */
window.cdJalonTermes = function(j){
  const t = [];
  if(j.tarif != null) t.push(cdArgent(j.tarif) + '/h');
  if(j.hd && j.hf) t.push(cdHeure(j.hd) + ' – ' + cdHeure(j.hf));
  return t.join(' · ');
};
})();
