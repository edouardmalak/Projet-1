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

/* ---- fil chronologique (DOM sûr — le message vient de l'utilisateur) ----
   Nécessite le CSS .fil / .jalon / .jalon-* (voir pages).             */
window.cdFilNegociation = function(texteJournal){
  const frag = document.createElement('div');
  frag.className = 'fil';
  cdJalons(texteJournal).forEach(j=>{
    if(j.auto) return;                       // refus automatique : bruit
    const el = document.createElement('div');
    el.className = 'jalon ' + (j.etape || '');
    const tete = document.createElement('div');
    tete.className = 'jalon-tete';
    const lib = document.createElement('b');
    lib.textContent = cdJalonLibelle(j);
    const quand = document.createElement('span');
    quand.textContent = cdQuand(j.quand);
    tete.append(lib, quand);
    el.appendChild(tete);
    const termes = cdJalonTermes(j);
    if(termes){
      const t = document.createElement('div');
      t.className = 'jalon-termes'; t.textContent = termes;
      el.appendChild(t);
    }
    if(j.message){
      const m = document.createElement('div');
      m.className = 'jalon-message'; m.textContent = '« ' + j.message + ' »';
      el.appendChild(m);
    }
    frag.appendChild(el);
  });
  return frag;
};

/* ---- entente finale : termes convenus d'une candidature acceptée ---- */
window.cdEntenteTexte = function(c, contrat){
  const hd = c.heure_debut_proposee || contrat.heure_debut;
  const hf = c.heure_fin_proposee || contrat.heure_fin;
  return cdArgent(c.tarif_propose) + '/h · ' + cdHeure(hd) + ' – ' + cdHeure(hf);
};

/* ---- alerte admin (Web3Forms) sur les évènements de candidature ----
   NOTE : la clé Web3Forms livre TOUJOURS à la boîte courriel de son
   propriétaire (Robert) — elle ne peut pas notifier dynamiquement le
   pharmacien ou la pharmacie eux-mêmes. C'est un correctif temporaire
   « alerte admin » en attendant la vraie solution par utilisateur
   (voir sql/06-notifications-email.sql, Resend + pg_net).
   Best-effort : échoue en silence si hors-ligne. ---- */
const CLE_ADMIN_ALERTE = "6d62e4bb-5cdd-42e9-8c64-5e9a9cf465eb";
window.cdAlerteAdmin = async function(sujet, message){
  try{
    await fetch('https://api.web3forms.com/submit', {
      method: 'POST',
      headers: {'Content-Type':'application/json; charset=utf-8','Accept':'application/json'},
      body: JSON.stringify({access_key: CLE_ADMIN_ALERTE, subject: '[C-Direct] ' + sujet, from_name: 'C-Direct', message: message})
    });
  }catch(e){ /* best-effort, ne bloque jamais le flux */ }
};
})();
