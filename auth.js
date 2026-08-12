// =====================================================
// AUTH.JS — helpers de session C-Direct (Supabase)
// Charger après supabase-config.js sur chaque page.
//
// ⚠️ EN MODIFIANT CE FICHIER, CHANGEZ AUSSI SA « CLÉ DE CACHE ».
// Les pages le chargent via <script src="/auth.js?v=AAAAMMJJx">. Le
// navigateur garde en cache le CONTENU associé à cette clé : si le code
// change mais pas la clé, l'usager continue d'exécuter l'ancienne version,
// éventuellement avec une page neuve — d'où des erreurs incompréhensibles.
// Commande (depuis le dossier du projet) :
//     sed -i '' 's|auth\.js?v=[0-9a-z]*|auth.js?v=NOUVELLE_CLE|g' *.html
// =====================================================
(function(){
const sb = window.sbClient;

/* ---- session + profil (avec petit cache) ---- */
window.cdSession = async function(){
  const { data } = await sb.auth.getSession();
  return data.session || null;
};

let _profil = null;
window.cdProfil = async function(force){
  if(_profil && !force) return _profil;
  const s = await cdSession();
  if(!s) return null;
  const { data, error } = await sb.from('profiles').select('*').eq('id', s.user.id).maybeSingle();
  if(error){ console.error('cdProfil:', error.message); return null; }
  _profil = data;
  return data;
};

/* ---- accueil selon le rôle ---- */
/* Chemins ABSOLUS : la fiche contrat vit sous /c/CD-XXXXXX (réécriture
   Cloudflare Pages) — les chemins relatifs y seraient cassés. */
window.cdAccueilPourRole = function(role){
  if(role === 'admin') return '/admin.html';
  if(role === 'pharmacie') return '/espace-pharmacie.html';
  return '/contrats.html'; // pharmacien
};

/* ---- garde : exige une connexion (et optionnellement des rôles) ----
   Usage : const p = await cdExigerConnexion(['pharmacie','admin']);      */
window.cdExigerConnexion = async function(roles){
  const s = await cdSession();
  if(!s){
    try{ localStorage.setItem('cd-suite', location.pathname + location.search); }catch(e){}
    location.replace('/acces.html?mode=conn');
    return new Promise(()=>{});
  }
  const p = await cdProfil();
  if(!p || !p.role || !p.consentement_date){
    // compte OAuth (Google) incomplet : rôle / consentement manquants
    try{ localStorage.setItem('cd-suite', location.pathname + location.search); }catch(e){}
    location.replace('/acces.html?mode=completer');
    return new Promise(()=>{});
  }
  if(p.compte_desactive === true){
    // désactivation volontaire (parametres.html) : la session reste valide
    // côté Supabase tant qu'on ne la ferme pas nous-mêmes — on le fait ici,
    // au point d'entrée commun à toutes les pages protégées.
    try{ localStorage.removeItem('cd-suite'); }catch(e){}
    window.__cdSortieVolontaire = true;   /* T6 (batch1) : sortie voulue, pas « expirée » */
    await sb.auth.signOut();
    location.replace('/acces.html?mode=conn&desactive=1');
    return new Promise(()=>{});
  }
  if(roles && roles.length && !roles.includes(p.role) && p.role !== 'admin'){
    location.replace(cdAccueilPourRole(p.role));
    return new Promise(()=>{});
  }
  /* compte non encore validé par l'admin : accès limité au profil
     (nécessaire à la vérification) — tout le reste va en salle d'attente.
     La base bloque de toute façon (RLS) ; ici c'est l'expérience. */
  if(p.role !== 'admin' && p.approuve !== true){
    const permis = ['/profil.html', '/attente.html'];
    if(!permis.includes(location.pathname)){
      location.replace('/attente.html');
      return new Promise(()=>{});
    }
  }
  return p;
};

/* ---- après connexion : reprendre l'URL visée ---- */
window.cdReprendreSuite = function(role){
  let suite = null;
  try{ suite = localStorage.getItem('cd-suite'); localStorage.removeItem('cd-suite'); }catch(e){}
  location.replace(suite || cdAccueilPourRole(role));
};

/* ---- T6 (batch1) : session expirée — gestion GLOBALE ----
   Avant : seule cdDiffuserContrat() gérait le 401 ; partout ailleurs,
   l'usager voyait le texte brut « JWT expired » de Supabase. Ici, on
   intercepte les réponses 401 de l'API de données (/rest/v1/ seulement —
   jamais /auth/v1/, sinon un mauvais mot de passe déclencherait tout ça),
   on tente UN rafraîchissement (même patron que cdDiffuserContrat), et si
   la session est réellement périmée : message bilingue + retour à la
   connexion en conservant la page visée (cd-suite). */
(function cdInterceptionSessionExpiree(){
  if(window.__cdIntercept401) return;
  window.__cdIntercept401 = true;
  let dejaTraite = false;

  function expiree(){
    if(dejaTraite) return;
    dejaTraite = true;
    try{ localStorage.setItem('cd-suite', location.pathname + location.search); }catch(e){}
    const bandeau = document.createElement('div');
    bandeau.textContent = cdT(
      'Votre session a expiré — reconnectez-vous.',
      'Your session has expired — please sign in again.');
    bandeau.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:9999;background:#C0392B;color:#fff;'+
      "text-align:center;padding:12px 16px;font-family:'Inter','Instrument Sans',sans-serif;font-size:14px;font-weight:600";
    (document.body || document.documentElement).appendChild(bandeau);
    setTimeout(()=>{ location.replace('/acces.html?mode=conn'); }, 1400);
  }

  /* Voie principale : GoTrue émet SIGNED_OUT quand le jeton de
     rafraîchissement est lui-même périmé/révoqué (auto-refresh échoué).
     Les déconnexions volontaires posent __cdSortieVolontaire avant
     signOut() (cdDeconnexion, désactivation) et sont ignorées ici. */
  try{
    sb.auth.onAuthStateChange(function(evenement){
      if(evenement === 'SIGNED_OUT' && !window.__cdSortieVolontaire) expiree();
    });
  }catch(e){}

  /* Voie complémentaire : réponses 401 de l'API de données. */
  const fetchOrigine = window.fetch;
  window.fetch = function(entree, options){
    const url = typeof entree === 'string' ? entree : (entree && entree.url) || '';
    const estDonnees = url.indexOf('/rest/v1/') !== -1;
    const r = fetchOrigine.apply(this, arguments);
    if(!estDonnees) return r;
    return r.then(function(rep){
      if(rep.status !== 401 || dejaTraite) return rep;
      /* un seul essai de rafraîchissement, comme cdDiffuserContrat */
      return sb.auth.refreshSession().then(function(res){
        const neuve = res && res.data && res.data.session;
        if(!neuve) expiree();
        return rep;
      }).catch(function(){ expiree(); return rep; });
    });
  };
})();

/* ---- confirmation « contrat confirmé » (courriel bilingue + PDF) ----
   Appelle le Worker DIRECTEMENT après une acceptation (plus fiable que les
   Database Webhooks). Authentifié par le jeton Supabase de l'usager.
   Fire-and-forget : ne bloque jamais l'interface, n'échoue jamais. */
window.cdConfirmerContrat = function(ref){
  if(!ref) return;
  cdSession().then(s=>{
    const token = s && s.access_token;
    if(!token) return;
    fetch('https://c-direct-sms.edouardmalak.workers.dev/confirmer', {
      method:'POST',
      headers:{ 'Content-Type':'application/json', 'Authorization':'Bearer '+token },
      body: JSON.stringify({ ref: ref })
    }).catch(function(){});
  }).catch(function(){});
};

/* ---- diffusion SMS d'un nouveau contrat (site → Worker) ----
   Renvoie une PROMESSE qui aboutit toujours (jamais de rejet) avec le
   compte rendu du Worker :
     { ok, contrat, pharmaciens_evalues, retenus, filtres, sms_envoyes,
       confirmation_pharmacie }
   ou { erreur: '…' } si l'appel n'a pas pu se faire.

   Historique : cette fonction avalait silencieusement le résultat
   (.catch vide, valeur jetée). Résultat concret : quand le filtrage
   écartait TOUS les pharmaciens — calendrier tenu sans la date, SMS
   désactivé, logiciel non maîtrisé — la pharmacie voyait « publié ✓ »
   sans jamais apprendre que personne n'avait été joint. On renvoie
   donc le compte rendu pour que l'interface puisse le dire. */
window.cdDiffuserContrat = function(ref){
  if(!ref) return Promise.resolve({ erreur: 'Référence manquante' });

  function appeler(token){
    return fetch('https://c-direct-sms.edouardmalak.workers.dev/diffuser', {
      method:'POST',
      headers:{ 'Content-Type':'application/json', 'Authorization':'Bearer '+token },
      body: JSON.stringify({ ref: ref })
    });
  }

  return cdSession().then(function(s){
    var token = s && s.access_token;
    if(!token) return { erreur: 'Session absente' };

    return appeler(token).then(function(r){
      /* Jeton expiré (onglet resté ouvert longtemps) : le Worker répond 401
         « Jeton invalide ». On rafraîchit la session et on réessaie UNE fois
         plutôt que d'annoncer un échec à la pharmacie. */
      if(r.status !== 401) return r;
      return sb.auth.refreshSession()
        .then(function(res){
          var neuf = res && res.data && res.data.session && res.data.session.access_token;
          return neuf ? appeler(neuf) : r;
        })
        .catch(function(){ return r; });
    }).then(function(r){
      /* Toujours 401 après rafraîchissement : la session est réellement
         périmée. On le dit en clair — « Jeton invalide » n'aide personne. */
      if(r.status === 401){
        return { erreur: 'session expirée — déconnectez-vous et reconnectez-vous, puis republiez' };
      }
      return r.json().catch(function(){ return { erreur: 'Réponse illisible ('+r.status+')' }; });
    });
  }).catch(function(e){
    return { erreur: (e && e.message) || 'Diffusion injoignable' };
  });
};

/* ---- envoi de la facture finale par courriel (site → Worker) ---- */
window.cdEnvoyerFacture = function(id){
  if(!id) return;
  cdSession().then(function(s){
    var token = s && s.access_token;
    if(!token) return;
    fetch('https://c-direct-sms.edouardmalak.workers.dev/facture', {
      method:'POST',
      headers:{ 'Content-Type':'application/json', 'Authorization':'Bearer '+token },
      body: JSON.stringify({ facture_id: id })
    }).catch(function(){});
  }).catch(function(){});
};

/* ---- déconnexion ---- */
window.cdDeconnexion = async function(){
  window.__cdSortieVolontaire = true;   /* T6 (batch1) : pas un cas « session expirée » */
  await sb.auth.signOut();
  _profil = null;
  location.href = '/index.html';
};

/* ---- menu de navigation selon le rôle ----
   Remplace les flèches « ← Retour » par un menu horizontal persistant.
   Injecté juste sous la topbar sur toutes les pages connectées. Bilingue
   (suit cdLang), surligne la page courante, masque les anciens liens
   « retour ». Format d'une entrée : soit un lien plat ['/href.html','FR','EN'],
   soit un groupe déroulant { g:'FR', ge:'EN', items:[[...],[...]] }.

   2026-08-08 — restructure « Apple-épuré » (dossier de refonte) : pharmacien
   ET pharmacie passent à 5 destinations À PLAT (plus aucun groupe déroulant
   dans la barre principale — un menu à un seul item n'a pas de sens).
   FAQ, Paramètres, Déconnexion, la note ★, et pour la pharmacie le badge de
   rôle, vivent maintenant dans le menu de compte (cdEnteteConnecte, plus
   bas) — pas ici. Maps devient un bouton de bascule DANS contrats.html (et
   son pendant DANS carte.html), pas une entrée de menu. L'accueil pharmacie
   (« Tableau de bord ») devient le clic sur le logo plutôt qu'une entrée —
   voir cdEnteteConnecte, qui rend .topbar .brand « sensible au rôle ».
   Chaque destination garde sa route existante — restructuration, pas
   reconstruction. Admin inchangé (hors périmètre du dossier de refonte). */
const CD_MENUS = {
  pharmacien: [
    ['/contrats.html',       'Trouver un contrat', 'Find a contract'],
    ['/mes-mandats.html',    'Mes contrats',       'My contracts'],
    ['/disponibilites.html', 'Agenda',             'Calendar'],
    ['/finances.html',       'Finances',           'Finances'],
    ['/messages.html',       'Messages',           'Messages']
  ],
  pharmacie: [
    /* Le vrai formulaire de publication vit dans espace-pharmacie.html.
       (L'ancien /demande.html est une page héritée : aucune connexion,
        aucune écriture en base — elle ne créait pas de contrat.) */
    ['/espace-pharmacie.html#nouvelle-demande', 'Publier un contrat', 'Post a contract'],
    ['/espace-pharmacie.html#a-pourvoir',       'Contrats affichés',  'Posted contracts'],
    ['/espace-pharmacie.html#mes-contrats',     'Contrats confirmés', 'Confirmed contracts'],
    ['/calendrier-pharmacie.html',              'Calendrier',         'Calendar'],
    ['/espace-pharmacie.html#factures-recues',  'Factures',           'Invoices'],
    ['/messages.html',                          'Messages',           'Messages']
  ],
  admin: [
    ['/admin.html',              'Console',          'Console'],
    ['/admin-verification.html', 'Vérification',     'Verification'],
    ['/admin-shifts.html',       'Contrats',         'Contracts'],
    ['/admin-articles.html',     'Dispensaire',       'Dispensary'],
    ['/admin-messages.html',     'Clavardage',       'Messages'],
    { g:'Compte', ge:'Account', items: [
      ['/evaluations.html',        'Évaluations',      'Reviews'],
      ['/profil.html',             'Profil',           'Profile'],
      ['/faq.html',                'FAQ',              'FAQ'],
      ['/parametres.html',         'Paramètres',       'Settings']
    ]}
  ]
};
window.cdMenuRole = function(role){
  if(document.getElementById('cd-menu')) return;         // idempotent
  const items = CD_MENUS[role] || CD_MENUS.pharmacien;
  const en = cdLang() === 'en';
  const ici = (location.pathname || '/').replace(/\.html$/,'').replace(/\/+$/,'') || '/';

  // Un seul bandeau : le menu vit DANS la topbar (même ligne que le logo et
  // le bloc session), pas dans une deuxième rangée en dessous. Overflow
  // visible (pas de scroll) pour laisser les menus déroulants s'afficher.
  const strip = document.createElement('span');
  strip.id = 'cd-menu';
  strip.setAttribute('role', 'navigation');
  strip.setAttribute('aria-label', en ? 'Main menu' : 'Menu principal');
  strip.style.cssText = "display:flex;align-items:center;gap:2px;flex:1 1 auto;min-width:0;"+
    "font-family:'IBM Plex Mono',monospace";

  // clé de comparaison pour « page active » — ignore l'ancre et .html
  const clePour = href => href.replace(/#.*$/,'').replace(/\.html$/,'');

  function creerLien(href, fr, an, premier){
    /* Une entrée qui pointe vers une ancre (#…) désigne une SECTION d'une
       page déjà présente au menu : on ne la surligne jamais, sinon deux
       entrées s'allumeraient en même temps (ex. Accueil + Nouvelle demande,
       qui vivent toutes deux dans espace-pharmacie.html). */
    const ancre = href.indexOf('#') !== -1;
    const actif = !ancre && ici === clePour(href);
    const a = document.createElement('a');
    a.href = href;
    a.textContent = en ? an : fr;
    a.setAttribute('aria-current', actif ? 'page' : 'false');
    /* T13b (batch1) : la 1re entrée (« Trouver un contrat » / « Publier un
       contrat ») est l'action principale — pastille pleine, distincte du
       simple surlignage de page active. */
    if(premier){
      a.style.cssText = 'white-space:nowrap;text-decoration:none;font-size:11px;letter-spacing:.04em;'+
        'text-transform:uppercase;padding:6px 12px;border-radius:99px;color:#fff;flex:none;display:block;'+
        'background:var(--vert,#0B6E4F);font-weight:700;margin-right:4px'+
        (actif ? ';outline:2px solid rgba(16,138,95,.35);outline-offset:1px' : '');
      a.addEventListener('mouseenter', ()=> a.style.background='var(--vert-fonce,#084C37)');
      a.addEventListener('mouseleave', ()=> a.style.background='var(--vert,#0B6E4F)');
      return a;
    }
    const couleur = actif ? 'var(--vert-vif,#0f8a5f)' : 'var(--sourd,#6b7772)';
    a.style.cssText = 'white-space:nowrap;text-decoration:none;font-size:11px;letter-spacing:.04em;'+
      'text-transform:uppercase;padding:6px 8px;border-radius:6px;color:'+couleur+';flex:none;display:block;'+
      (actif ? 'background:rgba(16,138,95,.10);font-weight:700' : 'font-weight:500');
    if(!actif){
      a.addEventListener('mouseenter', ()=> a.style.color='var(--vert-vif,#0f8a5f)');
      a.addEventListener('mouseleave', ()=> a.style.color='var(--sourd,#6b7772)');
    }
    return a;
  }

  const fermetures = [];
  function toutFermer(){ fermetures.forEach(f=>f()); }

  let groupePresent = false;
  items.forEach((entree, indice)=>{
    if(Array.isArray(entree)){
      strip.appendChild(creerLien(entree[0], entree[1], entree[2], indice === 0));
      return;
    }
    groupePresent = true;
    // groupe déroulant
    const actifEnfant = entree.items.some(([href])=> href.indexOf('#')===-1 && ici === clePour(href));
    const enveloppe = document.createElement('span');
    enveloppe.style.cssText = 'position:relative;flex:none';

    const bouton = document.createElement('button');
    bouton.type = 'button';
    bouton.textContent = (en ? entree.ge : entree.g) + ' ▾';
    bouton.setAttribute('aria-haspopup', 'true');
    bouton.setAttribute('aria-expanded', 'false');
    const couleurBtn = actifEnfant ? 'var(--vert-vif,#0f8a5f)' : 'var(--sourd,#6b7772)';
    bouton.style.cssText = 'white-space:nowrap;background:none;border:none;cursor:pointer;font:inherit;'+
      'font-size:11px;letter-spacing:.04em;text-transform:uppercase;padding:6px 8px;border-radius:6px;'+
      'color:'+couleurBtn+';'+(actifEnfant ? 'background:rgba(16,138,95,.10);font-weight:700' : 'font-weight:500');
    if(!actifEnfant){
      bouton.addEventListener('mouseenter', ()=> bouton.style.color='var(--vert-vif,#0f8a5f)');
      bouton.addEventListener('mouseleave', ()=> bouton.style.color='var(--sourd,#6b7772)');
    }

    const panneau = document.createElement('span');
    panneau.style.cssText = 'position:absolute;top:100%;left:0;margin-top:4px;background:var(--panneau,#fff);'+
      'border:1px solid var(--ligne,#E6E8E4);border-radius:10px;box-shadow:0 8px 24px -8px rgba(20,24,20,.18);'+
      'padding:6px;display:none;flex-direction:column;min-width:190px;z-index:60';
    entree.items.forEach(([href, fr, an])=>{
      const lien = creerLien(href, fr, an);
      lien.style.padding = '9px 10px';
      lien.style.fontSize = '12px';
      panneau.appendChild(lien);
    });

    function fermer(){ panneau.style.display='none'; bouton.setAttribute('aria-expanded','false'); }
    fermetures.push(fermer);
    bouton.addEventListener('click', e=>{
      e.stopPropagation();
      const estOuvert = panneau.style.display === 'flex';
      toutFermer();
      if(!estOuvert){ panneau.style.display='flex'; bouton.setAttribute('aria-expanded','true'); }
    });

    enveloppe.append(bouton, panneau);
    strip.appendChild(enveloppe);
  });

  document.addEventListener('click', toutFermer);
  document.addEventListener('keydown', e=>{ if(e.key === 'Escape') toutFermer(); });

  /* T13c (batch1) : point de rupture mobile — sous 900 px, la bande de
     nav défile horizontalement (barre de défilement masquée) au lieu de
     pousser ♥ / 🔔 / FR/EN / compte hors de l'écran. Les menus déroulants
     (admin : groupe « Compte ») exigent overflow visible → la règle est
     limitée aux bandes SANS groupe via la classe cd-menu-defile. */
  if(!groupePresent) strip.classList.add('cd-menu-defile');
  if(!document.getElementById('cd-style-menu-mobile')){
    const style = document.createElement('style');
    style.id = 'cd-style-menu-mobile';
    style.textContent =
      '@media(max-width:900px){' +
      '#cd-menu.cd-menu-defile{overflow-x:auto;overflow-y:hidden;scrollbar-width:none;-webkit-overflow-scrolling:touch}' +
      '#cd-menu.cd-menu-defile::-webkit-scrollbar{display:none}' +
      '.topbar .in{gap:8px}' +
      '}';
    document.head.appendChild(style);
  }

  const conteneur = document.querySelector('.topbar .droite') || document.querySelector('.topbar .in');
  if(conteneur){
    conteneur.style.minWidth = '0';
    conteneur.insertBefore(strip, conteneur.firstChild);
  } else {
    document.body.insertBefore(strip, document.body.firstChild);
  }

  // masquer les anciennes flèches « ← Retour » (le menu les remplace)
  document.querySelectorAll('.retour, a.retour, #lien-retour').forEach(el=>{ el.style.display = 'none'; });
};

/* ---- navigation arrière globale ----
   Remplace les anciennes flèches « ← Retour » posées page par page (déjà
   masquées par cdMenuRole ci-dessus) par UNE règle unique dans l'en-tête
   partagé : un chevron apparaît en haut à gauche sur toute page qui n'est
   PAS une « racine » — une destination directe du menu principal ou du
   menu de compte (Profil, Évaluations). Les racines sont calculées à partir
   de CD_MENUS lui-même : si un lien y est ajouté/retiré, la liste des
   racines suit automatiquement, pas besoin de la tenir à jour à la main.
   Site multi-pages classique (pas de routeur SPA) : le bouton n'utilise
   JAMAIS le bouton retour du navigateur — il appelle history.back()
   seulement quand le referrer confirme qu'on vient bien d'une page du même
   site (sinon on quitterait l'appli sans le vouloir) ; sinon il replie
   vers l'accueil du rôle, jamais une page blanche. */
function cdRacines(){
  const deMenu = Object.values(CD_MENUS).flat().flatMap(entree=>
    Array.isArray(entree) ? [entree[0]] : entree.items.map(i=>i[0])
  );
  /* destinations toujours atteignables via le cœur, la cloche ou le menu de
     compte (cdEnteteConnecte) — mêmes racines qu'un lien du menu principal,
     même si elles ne sont plus dans CD_MENUS depuis la restructure du
     2026-08-08 */
  const deCompte = [
    '/profil.html', '/evaluations.html', '/parametres.html', '/faq.html',
    '/dispensaire.html', '/pharmacies-preferees.html', '/locums-confiance.html',
    /* T11 (batch1) : carte.html est une sous-vue de Contrats avec sa propre
       bascule Liste/Calendrier/Maps — pas de chevron par-dessus (double
       affordance de retour) */
    '/carte.html'
  ];
  return [...deMenu, ...deCompte].map(h=> h.replace(/#.*$/,'').replace(/\.html$/,''));
}
function cdEstRacine(chemin){
  const ici = (chemin||'/').replace(/\.html$/,'').replace(/\/+$/,'') || '/';
  return cdRacines().some(r => r === ici);
}
window.cdBoutonRetour = function(role){
  if(document.getElementById('cd-retour')) return;               // idempotent
  if(cdEstRacine(location.pathname)) return;                      // racine : rien à afficher

  const bouton = document.createElement('button');
  bouton.id = 'cd-retour';
  bouton.type = 'button';
  bouton.setAttribute('aria-label', cdT('Retour', 'Back'));
  bouton.textContent = '←';
  bouton.style.cssText = 'background:none;border:none;cursor:pointer;font-size:19px;line-height:1;'+
    'color:var(--sourd,#5A6B63);padding:6px 10px 6px 2px;margin-right:2px;flex:none';
  bouton.addEventListener('mouseenter', ()=> bouton.style.color = 'var(--vert-vif,#0f8a5f)');
  bouton.addEventListener('mouseleave', ()=> bouton.style.color = 'var(--sourd,#5A6B63)');
  bouton.addEventListener('click', ()=>{
    let refMemeOrigine = false;
    try{ refMemeOrigine = !!document.referrer && new URL(document.referrer).origin === location.origin; }catch(e){}
    if(refMemeOrigine && window.history.length > 1) window.history.back();
    else location.href = cdAccueilPourRole(role);
  });

  const marque = document.querySelector('.topbar .brand');
  if(marque && marque.parentElement) marque.parentElement.insertBefore(bouton, marque);
};

/* ---- cœur (relations) + cloche (alertes) + FR/EN + menu de compte ----
   Petites briques du cluster de droite « Apple-épuré » (2026-08-08, dossier
   de refonte) — utilisées uniquement par cdEnteteConnecte ci-dessous. */
const SVG_COEUR = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.6l-1-1a5.5 5.5 0 0 0-7.8 7.8l1 1L12 21l7.8-7.8 1-1a5.5 5.5 0 0 0 0-7.8Z"/></svg>';
const SVG_CLOCHE = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8a6 6 0 1 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/></svg>';
const SVG_REGLAGE = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z"/></svg>';
const SVG_AIDE = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 14v-2a8 8 0 0 1 16 0v2"/><path d="M18 19a2 2 0 0 1-2 2h-2"/><rect x="2" y="14" width="4" height="6" rx="1"/><rect x="18" y="14" width="4" height="6" rx="1"/></svg>';

function cdIconeLien(href, svg, libelleFr, libelleEn){
  const a = document.createElement('a');
  a.href = href;
  a.setAttribute('aria-label', cdT(libelleFr, libelleEn));
  a.title = cdT(libelleFr, libelleEn);
  a.style.cssText = 'display:inline-flex;align-items:center;justify-content:center;width:32px;height:32px;'+
    'border-radius:8px;color:var(--sourd,#5A6B63);text-decoration:none;flex:none;position:relative';
  a.innerHTML = svg;
  a.addEventListener('mouseenter', ()=> a.style.color = 'var(--vert-vif,#0f8a5f)');
  a.addEventListener('mouseleave', ()=> a.style.color = 'var(--sourd,#5A6B63)');
  return a;
}
function cdPastilleSur(a){
  const p = document.createElement('span');
  p.style.cssText = 'display:none;position:absolute;top:1px;right:1px;min-width:14px;height:14px;padding:0 3px;'+
    "border-radius:99px;background:var(--rouge,#C0392B);color:#fff;font-size:9px;line-height:14px;text-align:center;"+
    "font-weight:700;font-family:'IBM Plex Mono',monospace";
  a.appendChild(p);
  return p;
}
function cdBoutonLangue(){
  const en = cdLang() === 'en';
  const enveloppe = document.createElement('span');
  enveloppe.style.cssText = 'display:inline-flex;border:1px solid var(--ligne,#E6E8E4);border-radius:99px;padding:2px;flex:none';
  ['fr','en'].forEach(l=>{
    const actif = l === (en ? 'en' : 'fr');
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = l.toUpperCase();
    b.setAttribute('aria-pressed', actif ? 'true' : 'false');
    b.style.cssText = 'border:none;cursor:pointer;font:inherit;font-size:10.5px;font-weight:700;letter-spacing:.04em;'+
      'padding:4px 9px;border-radius:99px;background:'+(actif ? 'var(--vert-vif,#0f8a5f)' : 'transparent')+';'+
      'color:'+(actif ? '#fff' : 'var(--sourd,#6b7772)');
    /* recharge la page pour ré-appliquer la langue partout (menus, textes
       data-fr/data-en) — un tap occasionnel, coût acceptable sur un site
       multi-pages sans routeur SPA */
    b.addEventListener('click', ()=>{
      if(actif) return;
      try{ localStorage.setItem('cd-lang', l); }catch(e){}
      location.reload();
    });
    enveloppe.appendChild(b);
  });
  return enveloppe;
}
/* items : ['/href','FR','EN'] (lien), ['---'] (séparateur),
   [null,'FR','EN', fonction, estDanger] (action), ou un nœud DOM déjà
   construit (inséré tel quel — sert à la ligne « Mon profil » du
   pharmacien, qui porte sa note ★ en plus du libellé). */
function cdMenuCompte(p, items, entete){
  const enveloppe = document.createElement('span');
  enveloppe.style.cssText = 'position:relative;display:inline-flex;flex:none';

  const bouton = document.createElement('button');
  bouton.type = 'button';
  bouton.setAttribute('aria-haspopup', 'true');
  bouton.setAttribute('aria-expanded', 'false');
  bouton.style.cssText = 'display:inline-flex;align-items:center;gap:7px;background:none;border:none;cursor:pointer;'+
    'font:inherit;color:var(--texte,#1B2622);padding:3px 6px 3px 3px;border-radius:99px';
  const nomPourInitiales = p.role === 'pharmacie' ? (p.nom_pharmacie||'') : ((p.prenom||'')+' '+(p.nom||''));
  const morceaux = nomPourInitiales.trim().split(/\s+/);
  const initiales = document.createElement('span');
  initiales.textContent = cdInitiales(morceaux[0], morceaux[1]);
  initiales.style.cssText = 'width:26px;height:26px;border-radius:50%;background:var(--vert,#0B6E4F);color:#fff;'+
    "display:grid;place-items:center;font-family:'Inter',sans-serif;font-weight:700;font-size:11px;flex:none";
  const nomTxt = document.createElement('span');
  nomTxt.textContent = p.role === 'pharmacie' ? (p.nom_pharmacie || p.ville || '') : (p.prenom || '');
  nomTxt.style.cssText = "font-family:'Inter',sans-serif;font-size:13.5px;font-weight:600;max-width:110px;"+
    'overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
  const chevron = document.createElement('span');
  chevron.textContent = '▾';
  chevron.style.cssText = 'font-size:10px;opacity:.6';
  bouton.append(initiales, nomTxt, chevron);

  const panneau = document.createElement('span');
  panneau.style.cssText = 'position:absolute;top:100%;right:0;margin-top:8px;background:var(--panneau,#fff);'+
    'border:1px solid var(--ligne,#E6E8E4);border-radius:12px;box-shadow:0 8px 24px -8px rgba(20,24,20,.18);'+
    'padding:8px;display:none;flex-direction:column;min-width:210px;z-index:70';

  if(entete){
    entete.style.cssText += ';padding:6px 10px 10px;margin-bottom:4px;border-bottom:1px solid var(--ligne,#E6E8E4)';
    panneau.appendChild(entete);
  }
  items.forEach(item=>{
    if(item instanceof Node){ panneau.appendChild(item); return; }
    if(item[0] === '---'){
      const sep = document.createElement('div');
      sep.style.cssText = 'height:1px;background:var(--ligne,#E6E8E4);margin:6px 4px';
      panneau.appendChild(sep);
      return;
    }
    const [href, fr, en, action, danger] = item;
    const lien = document.createElement(action ? 'button' : 'a');
    if(action){ lien.type = 'button'; lien.addEventListener('click', action); }
    else lien.href = href;
    lien.textContent = cdT(fr, en);
    lien.style.cssText = "display:block;width:100%;text-align:left;background:none;border:none;padding:9px 10px;"+
      "font-family:'Inter',sans-serif;font-size:13px;text-decoration:none;border-radius:7px;cursor:pointer;"+
      'color:'+(danger ? 'var(--rouge,#C0392B)' : 'var(--texte,#1B2622)');
    lien.addEventListener('mouseenter', ()=> lien.style.background = 'var(--panneau2,#F1F6F2)');
    lien.addEventListener('mouseleave', ()=> lien.style.background = 'none');
    panneau.appendChild(lien);
  });

  function fermer(){ panneau.style.display = 'none'; bouton.setAttribute('aria-expanded','false'); }
  bouton.addEventListener('click', e=>{
    e.stopPropagation();
    const ouvert = panneau.style.display === 'flex';
    fermer();
    if(!ouvert){ panneau.style.display = 'flex'; bouton.setAttribute('aria-expanded','true'); }
  });
  document.addEventListener('click', fermer);
  document.addEventListener('keydown', e=>{ if(e.key === 'Escape') fermer(); });

  enveloppe.append(bouton, panneau);
  return enveloppe;
}

/* ---- bouton « Aide » (barre du haut) ---- */
function cdBoutonAide(role){
  const b = document.createElement('button');
  b.type = 'button';
  b.setAttribute('aria-haspopup', 'dialog');
  b.setAttribute('aria-label', cdT('Aide', 'Help'));
  b.style.cssText = 'display:inline-flex;align-items:center;gap:6px;background:var(--menthe,#E7F2EC);'+
    'color:var(--vert,#0B6E4F);border:none;border-radius:99px;padding:6px 12px;cursor:pointer;flex:none;'+
    "font-family:'Inter',sans-serif;font-size:13px;font-weight:600";
  b.innerHTML = SVG_AIDE + '<span>' + cdT('Aide', 'Help') + '</span>';
  b.addEventListener('click', ()=> cdOuvrirAide(role));
  return b;
}

/* ---- petite fenêtre modale générique (aide + réservation) ---- */
function cdModale(titre){
  const overlay = document.createElement('div');
  overlay.setAttribute('role', 'dialog');
  overlay.setAttribute('aria-modal', 'true');
  overlay.style.cssText = 'position:fixed;inset:0;background:rgba(15,20,18,.5);z-index:200;display:flex;'+
    'align-items:center;justify-content:center;padding:18px';
  const card = document.createElement('div');
  card.style.cssText = 'background:var(--panneau,#fff);border-radius:14px;width:100%;max-width:440px;'+
    'max-height:92vh;overflow:auto;box-shadow:0 20px 60px -20px rgba(0,0,0,.4)';
  const tete = document.createElement('div');
  tete.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:10px;padding:12px 16px;'+
    'border-bottom:1px solid var(--ligne,#E6E8E4);position:sticky;top:0;background:var(--panneau,#fff);z-index:1';
  const t = document.createElement('span');
  t.textContent = titre;
  t.style.cssText = "font-family:'Inter',sans-serif;font-size:14px;color:var(--sourd,#5A6B63)";
  const x = document.createElement('button');
  x.type = 'button'; x.innerHTML = '&times;';
  x.setAttribute('aria-label', cdT('Fermer', 'Close'));
  x.style.cssText = 'background:none;border:none;font-size:24px;line-height:1;cursor:pointer;color:var(--sourd,#5A6B63)';
  function fermer(){ overlay.remove(); document.removeEventListener('keydown', onKey); }
  function onKey(e){ if(e.key === 'Escape') fermer(); }
  x.addEventListener('click', fermer);
  overlay.addEventListener('click', e=>{ if(e.target === overlay) fermer(); });
  document.addEventListener('keydown', onKey);
  tete.append(t, x);
  const corps = document.createElement('div');
  corps.style.cssText = 'padding:20px';
  card.append(tete, corps);
  overlay.appendChild(card);
  document.body.appendChild(overlay);
  return { overlay, corps, fermer };
}

/* ---- panneau « Aide » : entrevue (pharmacien/ATP) + nous écrire + FAQ ----
   pharmacie : soutien seulement (pas d'entrevue). */
window.cdOuvrirAide = async function(role){
  const m = cdModale(cdT('Aide', 'Help'));
  const bloc = (html)=>{ const d = document.createElement('div'); d.innerHTML = html; return d; };

  if(role === 'pharmacien'){
    const carte = document.createElement('div');
    carte.style.cssText = 'border:1px solid var(--ligne,#E6E8E4);border-radius:12px;padding:18px;margin-bottom:12px';
    carte.appendChild(bloc(
      '<div style="display:flex;align-items:center;gap:12px;margin-bottom:12px">'+
        '<span style="width:44px;height:44px;border-radius:10px;background:var(--menthe,#E7F2EC);color:var(--vert,#0B6E4F);display:grid;place-items:center">'+SVG_AIDE.replace('width="16" height="16"','width="22" height="22"')+'</span>'+
        '<div><div style="font-family:\'Inter\',sans-serif;font-weight:600;font-size:16px">'+cdT('Entrevue d\'intégration','Onboarding interview')+'</div>'+
        '<div style="font-size:13px;color:var(--sourd,#5A6B63)">'+cdT('Une courte rencontre avant l\'activation de votre compte.','A short meeting before your account is activated.')+'</div></div>'+
      '</div>'+
      '<div id="cd-aide-statut" style="font-size:13px;color:var(--sourd,#5A6B63);margin-bottom:12px">'+cdT('Chargement…','Loading…')+'</div>'
    ));
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = cdT('Prendre rendez-vous', 'Book an appointment');
    btn.style.cssText = 'width:100%;background:var(--vert,#0B6E4F);color:#fff;border:none;border-radius:8px;'+
      "padding:13px;font-family:'Inter',sans-serif;font-size:15px;font-weight:600;cursor:pointer";
    btn.addEventListener('click', ()=>{ m.fermer(); cdOuvrirReservation({ type:'entrevue' }); });
    carte.appendChild(btn);
    m.corps.appendChild(carte);

    /* état de l'entrevue courante */
    try{
      const { data } = await sb.rpc('mes_rendez_vous');
      const rv = (data||[]).find(r=> r.type==='entrevue' && r.statut!=='annule');
      const z = m.corps.querySelector('#cd-aide-statut');
      if(z){
        if(!rv){
          z.textContent = cdT('Aucune entrevue planifiée pour l\'instant.','No interview scheduled yet.');
        }else{
          const quand = rv.date_confirmee || rv.date_souhaitee;
          const qtxt = quand ? new Date(quand).toLocaleString(cdLang()==='en'?'en-CA':'fr-CA',{dateStyle:'long',timeStyle:'short'}) : '';
          const lib = {demande:cdT('Demande envoyée — en attente de confirmation.','Request sent — awaiting confirmation.'),
                       confirme:cdT('Entrevue confirmée : ','Interview confirmed: ')+qtxt,
                       propose:cdT('Nouvelle plage proposée : ','New time proposed: ')+qtxt,
                       complete:cdT('Entrevue complétée.','Interview completed.')};
          z.textContent = lib[rv.statut] || rv.statut;
          btn.textContent = (rv.statut==='complete') ? cdT('Reprendre rendez-vous','Book again') : cdT('Modifier / reprendre','Change / rebook');
        }
      }
    }catch(e){}
  }

  const ecrire = document.createElement('a');
  ecrire.href = 'mailto:info@c-direct.ca';
  ecrire.style.cssText = 'display:flex;align-items:center;gap:12px;border:1px solid var(--ligne,#E6E8E4);'+
    'border-radius:12px;padding:14px 16px;text-decoration:none;color:var(--texte,#1B2622);margin-bottom:10px';
  ecrire.innerHTML = '<span style="color:var(--vert,#0B6E4F);display:inline-flex"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/></svg></span>'+
    '<div><div style="font-family:\'Inter\',sans-serif;font-weight:600;font-size:15px">'+cdT('Nous écrire','Write to us')+'</div>'+
    '<div style="font-size:13px;color:var(--sourd,#5A6B63)">'+cdT('Une question ? L\'équipe répond rapidement.','A question? The team replies quickly.')+'</div></div>';
  m.corps.appendChild(ecrire);

  const faq = document.createElement('a');
  faq.href = '/faq.html';
  faq.style.cssText = 'display:block;text-align:center;font-family:\'Inter\',sans-serif;font-size:13px;'+
    'color:var(--vert-vif,#0f8a5f);text-decoration:underline;text-underline-offset:3px;margin-top:4px';
  faq.textContent = cdT('Consulter la FAQ', 'Read the FAQ');
  m.corps.appendChild(faq);
};

/* ---- fenêtre de réservation (entrevue ou soutien) ----
   Réutilisée par le panneau Aide ET par attente.html (écran d'entrée). */
window.cdOuvrirReservation = async function(opts){
  opts = opts || {};
  const type = opts.type === 'soutien' ? 'soutien' : 'entrevue';
  const m = cdModale(type === 'entrevue' ? cdT('Entrevue d\'intégration','Onboarding interview') : cdT('Rendez-vous','Appointment'));

  const p = (typeof cdProfil === 'function') ? (await cdProfil().catch(()=>null)) : null;

  /* créneaux 08:00 → 18:00 par 30 min */
  let opts_heure = '<option value="">' + cdT('Choisir une heure','Choose a time') + '</option>';
  for(let h=8; h<=18; h++){ for(const mn of ['00','30']){ if(h===18 && mn==='30') break; const v=(h<10?'0'+h:h)+':'+mn; opts_heure += '<option value="'+v+'">'+v+'</option>'; } }

  const champ = 'width:100%;border:1px solid var(--ligne2,#C3D6CB);border-radius:8px;padding:10px 11px;'+
    "font-size:14px;font-family:'Inter',sans-serif;background:#F4F8F5;color:var(--texte,#1B2622);box-sizing:border-box";
  const lab = 'display:block;font-size:12px;color:var(--sourd,#5A6B63);margin-bottom:5px';

  m.corps.innerHTML =
    '<p style="margin:0 0 4px;font-family:\'Inter\',sans-serif;font-weight:600;font-size:18px;text-align:center">'+cdT('Planifions votre rendez-vous','Let\'s schedule your appointment')+'</p>'+
    '<p style="margin:0 0 16px;font-size:13px;color:var(--sourd,#5A6B63);text-align:center">'+cdT('Choisissez le moment qui vous convient.','Pick the time that works for you.')+'</p>'+
    '<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px">'+
      '<div><label style="'+lab+'">'+cdT('Date','Date')+'</label><input id="rv-date" type="date" style="'+champ+'"></div>'+
      '<div><label style="'+lab+'">'+cdT('Heure','Time')+'</label><select id="rv-heure" style="'+champ+'">'+opts_heure+'</select></div>'+
    '</div>'+
    '<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px">'+
      '<div><label style="'+lab+'">'+cdT('Prénom','First name')+'</label><input id="rv-prenom" style="'+champ+'"></div>'+
      '<div><label style="'+lab+'">'+cdT('Nom','Last name')+'</label><input id="rv-nom" style="'+champ+'"></div>'+
    '</div>'+
    '<div style="margin-bottom:12px"><label style="'+lab+'">'+cdT('Adresse courriel','Email address')+'</label><input id="rv-courriel" type="email" style="'+champ+'"></div>'+
    '<div style="margin-bottom:16px"><label style="'+lab+'">'+cdT('Numéro de téléphone','Phone number')+'</label><input id="rv-tel" type="tel" style="'+champ+'"></div>'+
    '<div id="rv-err" style="display:none;background:rgba(192,57,43,.08);color:var(--rouge,#C0392B);border-radius:8px;padding:9px 12px;font-size:13px;margin-bottom:12px"></div>'+
    '<button id="rv-envoyer" type="button" style="width:100%;background:var(--vert,#0B6E4F);color:#fff;border:none;border-radius:8px;padding:13px;font-family:\'Inter\',sans-serif;font-size:15px;font-weight:600;cursor:pointer">'+cdT('Prendre rendez-vous','Book appointment')+'</button>';

  const g = id => m.corps.querySelector('#'+id);
  if(p){
    g('rv-prenom').value = p.prenom || '';
    g('rv-nom').value = p.nom || '';
    g('rv-courriel').value = p.courriel || '';
    g('rv-tel').value = (typeof cdTelAffiche==='function' ? cdTelAffiche(p.telephone) : p.telephone) || '';
  }
  const errZone = g('rv-err');
  const err = (msg)=>{ errZone.textContent = msg; errZone.style.display = 'block'; };

  g('rv-envoyer').addEventListener('click', async ()=>{
    const d = g('rv-date').value, h = g('rv-heure').value;
    if(!d || !h){ err(cdT('Choisissez une date et une heure.','Choose a date and a time.')); return; }
    if(!g('rv-prenom').value.trim() || !g('rv-nom').value.trim()){ err(cdT('Entrez votre prénom et votre nom.','Enter your first and last name.')); return; }
    if(!g('rv-courriel').value.trim()){ err(cdT('Entrez votre courriel.','Enter your email.')); return; }
    const quand = new Date(d + 'T' + h + ':00');
    if(isNaN(quand.getTime())){ err(cdT('Date ou heure invalide.','Invalid date or time.')); return; }
    const btn = g('rv-envoyer'); btn.disabled = true; btn.textContent = cdT('Envoi…','Sending…');
    const note = (cdT('Contact : ','Contact: ') + g('rv-prenom').value.trim() + ' ' + g('rv-nom').value.trim()
                  + ' · ' + g('rv-courriel').value.trim() + ' · ' + g('rv-tel').value.trim()).trim();
    const { error } = await sb.rpc('demander_rendez_vous', { p_date_souhaitee: quand.toISOString(), p_type: type, p_message: note });
    if(error){ btn.disabled = false; btn.textContent = cdT('Prendre rendez-vous','Book appointment'); err(cdT('Erreur : ','Error: ') + error.message); return; }
    const qtxt = quand.toLocaleString(cdLang()==='en'?'en-CA':'fr-CA', { dateStyle:'long', timeStyle:'short' });
    if(typeof cdAlerteAdmin === 'function'){
      cdAlerteAdmin(
        cdT('Nouvelle demande d\'entrevue', 'New interview request'),
        cdT((p && (p.prenom||p.courriel) || 'Un usager') + ' souhaite une ' + (type==='entrevue'?'entrevue':'rencontre') + ' le ' + qtxt + '. ' + note,
            (p && (p.prenom||p.courriel) || 'A user') + ' requested ' + (type==='entrevue'?'an interview':'a call') + ' on ' + qtxt + '. ' + note)
      );
    }
    m.corps.innerHTML = '<div style="text-align:center;padding:16px 8px">'+
      '<div style="width:48px;height:48px;border-radius:50%;background:var(--menthe,#E7F2EC);color:var(--vert,#0B6E4F);display:grid;place-items:center;margin:0 auto 14px;font-size:26px">✓</div>'+
      '<p style="font-family:\'Inter\',sans-serif;font-weight:600;font-size:17px;margin:0 0 6px">'+cdT('Demande envoyée','Request sent')+'</p>'+
      '<p style="font-size:14px;color:var(--sourd,#5A6B63);margin:0">'+cdT('Nous vous confirmerons le rendez-vous du ','We\'ll confirm your appointment for ')+qtxt+cdT(' rapidement.',' shortly.')+'</p>'+
      '</div>';
    if(typeof opts.onDone === 'function') opts.onDone();
  });
};

/* ---- en-tête connecté : injecte le cluster de session dans la topbar ----
   Pharmacien/pharmacie : cœur + cloche + FR/EN + menu de compte, façon
   « Apple-épuré » (2026-08-08, dossier de refonte). Admin : rendu inchangé
   (NOM · ★ note · DÉCONNEXION à plat) — hors périmètre du dossier, aucune
   raison de le retoucher. */
window.cdEnteteConnecte = async function(){
  const p = await cdProfil();
  if(!p) return null;
  const conteneur = document.querySelector('.topbar .droite') ||
                    document.querySelector('.topbar .in') ||
                    document.querySelector('.topbar .wrap');
  if(conteneur && (p.role === 'pharmacien' || p.role === 'pharmacie')){
    /* T17 (batch1) : interrupteur admin — regles_reseau.dispensaire_visible
       (sql/76) retire « Formations »/« Dispensaire » des menus de compte.
       Défaut : visible (si colonne absente, erreur, ou migration pas passée). */
    let dispensaireVisible = true;
    try{
      const { data: rr } = await sb.from('regles_reseau').select('dispensaire_visible').eq('id',1).maybeSingle();
      if(rr && rr.dispensaire_visible === false) dispensaireVisible = false;
    }catch(e){}

    const el = document.createElement('span');
    el.id = 'cd-entete-session';
    el.style.cssText = 'display:inline-flex;align-items:center;gap:6px;flex:none';

    const coeur = cdIconeLien(
      p.role === 'pharmacien' ? '/pharmacies-preferees.html' : '/locums-confiance.html',
      SVG_COEUR,
      p.role === 'pharmacien' ? 'Pharmacies préférées' : 'Locums de confiance',
      p.role === 'pharmacien' ? 'Preferred pharmacies' : 'Trusted locums'
    );
    /* T2 (batch1) : la pastille compte les messages non lus (sql/60) —
       la cloche pointe donc vers l'écran qui les affiche (/messages.html),
       pas vers le Dispensaire (bibliothèque d'articles). */
    const cloche = cdIconeLien('/messages.html', SVG_CLOCHE, 'Alertes et messages', 'Alerts and messages');
    const pastilleCloche = cdPastilleSur(cloche);

    /* réputation + favoris reçus — chargés en différé plus bas ; les
       variables restent valides même une fois les nœuds déplacés dans le
       panneau du menu de compte */
    const etoiles = document.createElement('a');
    etoiles.href = '/evaluations.html';
    etoiles.style.cssText = "display:none;color:var(--jaune,#C97B12);text-decoration:none;font-weight:600;font-size:12.5px;white-space:nowrap";
    const favoris = document.createElement('span');
    favoris.style.cssText = 'display:none;color:var(--rouge,#C0392B);font-weight:600;font-size:12.5px;margin-left:8px;white-space:nowrap';

    let entete = null, items;
    if(p.role === 'pharmacien'){
      /* « Mon profil » porte sa note ★ à même la ligne (dossier de refonte) —
         pas d'en-tête séparé pour ce rôle. Rangée en <div> (pas <a>) : elle
         contient à la fois le lien Profil et le lien ★ Évaluations, et un
         <a> ne peut pas légalement en contenir un autre (HTML invalide,
         comportement de clic imprévisible selon le navigateur). */
      const ligneProfil = document.createElement('div');
      ligneProfil.style.cssText = 'display:flex;align-items:center;justify-content:space-between;gap:8px;'+
        'padding:1px 1px 1px 1px;border-radius:7px';
      ligneProfil.addEventListener('mouseenter', ()=> ligneProfil.style.background='var(--panneau2,#F1F6F2)');
      ligneProfil.addEventListener('mouseleave', ()=> ligneProfil.style.background='none');
      const libelleProfil = document.createElement('a');
      libelleProfil.href = '/profil.html';
      libelleProfil.textContent = cdT('Mon profil','My profile');
      libelleProfil.style.cssText = "flex:1;padding:8px 9px;font-family:'Inter',sans-serif;font-size:13px;"+
        'text-decoration:none;color:var(--texte,#1B2622);white-space:nowrap';
      ligneProfil.append(libelleProfil, etoiles, favoris);
      items = [
        ligneProfil,
        ...(dispensaireVisible ? [['/dispensaire.html', 'Formations', 'Training']] : []),
        ['/parametres.html',  'Paramètres', 'Settings'],
        /* T13a (batch1) : l'ancien bouton « Aide » de la barre est replié
           ici — ouvre le même panneau (entrevue + nous écrire + FAQ). */
        [null, 'Aide & FAQ', 'Help & FAQ', ()=> cdOuvrirAide(p.role)],
        ['---'],
        [null, 'Déconnexion', 'Log out', cdDeconnexion, true]
      ];
    } else {
      entete = document.createElement('div');
      entete.append(etoiles, favoris); // favoris : caché côté pharmacie (n'a de sens que côté pharmacien)
      const tag = document.createElement('span');
      tag.textContent = cdT('Pharmacie','Pharmacy');
      tag.style.cssText = 'display:inline-block;margin-top:4px;padding:2px 7px;border-radius:3px;'+
        "font-family:'IBM Plex Mono',monospace;font-size:9.5px;font-weight:700;letter-spacing:.08em;"+
        'color:#17C980;border:1px solid rgba(23,201,128,.45);background:rgba(18,169,110,.1)';
      entete.appendChild(tag);
      items = [
        ['/profil.html',      'Profil',      'Profile'],
        ...(dispensaireVisible ? [['/dispensaire.html', 'Dispensaire', 'Dispensary']] : []),
        ['/evaluations.html', 'Évaluations', 'Reviews'],
        ['/parametres.html',  'Paramètres',  'Settings'],
        /* T13a (batch1) : bouton « Aide » replié ici (même panneau) */
        [null, 'Aide & FAQ', 'Help & FAQ', ()=> cdOuvrirAide(p.role)],
        ['---'],
        [null, 'Déconnexion', 'Log out', cdDeconnexion, true]
      ];
    }
    const compte = cdMenuCompte(p, items, entete);
    /* T13a (batch1) : ordre approuvé — liens de nav · ♥ · 🔔 · FR/EN · menu
       de compte. Le ⚙ autonome et le bouton « Aide » sont repliés dans le
       menu de compte (Paramètres et Aide & FAQ y vivent déjà). */
    el.append(coeur, cloche, cdBoutonLangue(), compte);
    conteneur.appendChild(el);

    /* logo = accueil du rôle plutôt que la page publique, pour les deux
       rôles connectés (le dossier ne le demande explicitement que côté
       pharmacie — « Logo click = Tableau de bord » — étendu au pharmacien
       par cohérence : les deux barres sont censées se refléter) */
    const brand = document.querySelector('.topbar .brand');
    if(brand) brand.href = cdAccueilPourRole(p.role);

    document.querySelectorAll('a[href^="acces.html"],a[href^="/acces.html"]').forEach(a=>{
      if(/mode=(conn|insc)/.test(a.getAttribute('href'))) a.style.display = 'none';
    });

    sb.rpc('get_note_profil', { p_profil: p.id }).then(({ data })=>{
      const n = data && data[0];
      if(n && n.nombre > 0){
        etoiles.textContent = '★ ' + Number(n.moyenne).toFixed(1) + ' (' + n.nombre + ')';
        etoiles.style.display = '';
      }
    }).catch(()=>{});
    if(p.role === 'pharmacien'){
      /* état 'trusted' seulement — depuis sql/61, cette table porte aussi
         les relations 'muted'/'blocked' ; les compter ici gonflerait « ♥ »
         avec des pharmacies qui ont justement mis ce pharmacien de côté */
      sb.from('favoris_pharmaciens').select('*', { count:'exact', head:true })
        .eq('pharmacien_id', p.id).eq('state', 'trusted')
        .then(({ count })=>{
          if(count > 0){ favoris.textContent = '♥ ' + count; favoris.style.display = ''; }
        }).catch(()=>{});
    }
    /* pastille de la cloche — réutilise le compteur de messages non lus
       (sql/60), seule source d'« alertes personnelles » déjà en place
       (candidatures/messages) ; il n'existe pas de table de nouvelles
       distincte pour le volet « platform news » du dossier de refonte. */
    sb.rpc('compter_messages_non_lus').then(({ data, error })=>{
      if(error || !data || data <= 0) return;
      pastilleCloche.textContent = data > 99 ? '99+' : String(data);
      pastilleCloche.style.display = 'inline-block';
    }).catch(()=>{});
  } else if(conteneur){
    /* ---- admin : rendu inchangé (hors périmètre du dossier de refonte) ---- */
    const el = document.createElement('span');
    el.id = 'cd-entete-session';
    el.style.cssText = "display:inline-flex;align-items:center;gap:10px;font-family:'IBM Plex Mono',monospace;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase;white-space:nowrap;flex:none";
    const roleBadge = document.createElement('span');
    roleBadge.textContent = 'ADMIN';
    roleBadge.style.cssText = 'padding:2px 8px;border-radius:3px;border:1px solid;font-size:10px;font-weight:700;letter-spacing:.1em;'+
      'color:#E8B849;border-color:rgba(232,184,73,.55);background:rgba(232,184,73,.1)';
    const nom = document.createElement('b');
    nom.textContent = p.prenom || p.courriel || '';
    nom.style.cssText = 'color:inherit;text-decoration:none;font-weight:700';
    const etoiles = document.createElement('a');
    etoiles.href = '/evaluations.html';
    etoiles.style.cssText = 'display:none;color:var(--jaune,#C97B12);text-decoration:none;font-weight:600;letter-spacing:.02em';
    const sep = document.createElement('span'); sep.textContent = '·'; sep.style.opacity = '.5';
    const btn = document.createElement('button');
    btn.textContent = cdT('Déconnexion', 'Log out');
    btn.style.cssText = "background:none;border:none;cursor:pointer;color:inherit;font:inherit;text-decoration:underline;text-underline-offset:3px;opacity:.8";
    btn.onclick = cdDeconnexion;
    el.append(roleBadge, nom, etoiles, sep, btn);
    const brand = document.querySelector('.topbar .brand');
    if(brand && brand.parentElement){
      const groupe = document.createElement('span');
      groupe.style.cssText = 'display:flex;align-items:center;gap:10px;min-width:0';
      brand.parentElement.insertBefore(groupe, brand);
      groupe.append(brand, el);
    } else {
      conteneur.appendChild(el);
    }
    document.querySelectorAll('a[href^="acces.html"],a[href^="/acces.html"]').forEach(a=>{
      if(/mode=(conn|insc)/.test(a.getAttribute('href'))) a.style.display = 'none';
    });
  }
  if(p && p.role) cdMenuRole(p.role);
  if(p && p.role) cdBoutonRetour(p.role);
  if(p && p.role) cdBadgeMessagesNonLus(p.role);
  return p;
};

/* ---- pastille "nouveaux messages" sur le lien Clavardage du menu ----
   sql/60. Un seul compteur (compter_messages_non_lus) couvre les fils
   pharmacie<->pharmacien ET le nouveau canal admin<->utilisateur — peu
   importe le rôle, un seul appel. Best-effort : jamais bloquant, jamais
   de pastille si l'appel échoue (fonctionnalité secondaire). */
async function cdBadgeMessagesNonLus(role){
  const href = role === 'admin' ? '/admin-messages.html' : '/messages.html';
  const lien = document.querySelector('#cd-menu a[href="'+href+'"]');
  if(!lien) return;

  async function rafraichir(){
    let data;
    try{
      const r = await sb.rpc('compter_messages_non_lus');
      if(r.error) return;
      data = r.data;
    }catch(e){ return; }
    let pastille = lien.querySelector('.cd-pastille-non-lus');
    if(!data || data <= 0){
      if(pastille) pastille.remove();
      return;
    }
    if(!pastille){
      pastille = document.createElement('span');
      pastille.className = 'cd-pastille-non-lus';
      pastille.style.cssText = 'display:inline-block;min-width:15px;height:15px;padding:0 3px;margin-left:5px;'+
        'border-radius:99px;background:var(--rouge,#C0392B);color:#fff;font-size:9.5px;line-height:15px;'+
        'text-align:center;font-weight:700;vertical-align:middle';
      lien.appendChild(pastille);
    }
    pastille.textContent = data > 99 ? '99+' : String(data);
  }

  await rafraichir();
  setInterval(rafraichir, 45000);
}

/* Bannière "N nouveaux messages" pour l'écran principal de chaque rôle —
   même compteur que la pastille de nav (compter_messages_non_lus, sql/60),
   juste plus visible avec un lien direct. Le conteneur doit déjà exister
   dans le HTML de la page ; reste vide si 0 message (jamais bloquant). */
window.cdBanniereMessagesNonLus = async function(idConteneur, lienInbox){
  const zone = document.getElementById(idConteneur);
  if(!zone) return;
  try{
    const { data, error } = await sb.rpc('compter_messages_non_lus');
    if(error || !data || data <= 0){ zone.innerHTML = ''; return; }
    zone.innerHTML = '<a href="'+lienInbox+'" style="display:flex;align-items:center;gap:10px;'+
      'background:rgba(192,57,43,.06);border:1px solid rgba(192,57,43,.3);border-radius:8px;'+
      'padding:12px 14px;margin-bottom:16px;text-decoration:none;color:var(--rouge,#C0392B);'+
      'font-family:\'IBM Plex Mono\',monospace;font-size:13px;font-weight:700">'+
      '💬 '+data+' nouveau'+(data>1?'x':'')+' message'+(data>1?'s':'')+' — voir la messagerie →</a>';
  }catch(e){ /* fonctionnalité secondaire, jamais bloquant */ }
};

/* ---- téléphone : normalisation E.164 (+1XXXXXXXXXX) ---- */
window.cdE164 = function(tel){
  if(!tel) return null;
  let d = String(tel).replace(/\D/g,'');
  if(d.length === 11 && d.startsWith('1')) d = d.slice(1);
  return d.length === 10 ? '+1' + d : null;
};
window.cdTelAffiche = function(e164){
  if(!e164) return '';
  const d = String(e164).replace(/\D/g,'').replace(/^1/,'');
  return d.length === 10 ? d.slice(0,3)+'-'+d.slice(3,6)+'-'+d.slice(6) : e164;
};

/* ---- formatage ---- */
/* T5 (batch1) : date du jour LOCALE 'YYYY-MM-DD' — jamais toISOString(),
   qui bascule au lendemain dès ~20 h (heure du Québec) parce qu'il rend
   la date UTC. À utiliser pour tout « aujourd'hui » calendaire. */
window.cdAujourdhui = function(){
  const d = new Date();
  return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');
};
window.cdArgent = n => new Intl.NumberFormat('fr-CA',{minimumFractionDigits:2,maximumFractionDigits:2}).format(n)+' $';
window.cdDate = d => new Date(d + (String(d).length===10 ? 'T12:00:00' : '')).toLocaleDateString('fr-CA',{weekday:'short',year:'numeric',month:'short',day:'numeric'});
window.cdHeure = h => String(h||'').slice(0,5).replace(':',' h ');

/* ---- temps relatif (messagerie : "à l'instant", "12 min", "3 h", "hier", "5 j", puis date courte) ---- */
window.cdTempsRelatif = function(dateISO){
  if(!dateISO) return '';
  const d = new Date(dateISO);
  if(isNaN(d)) return '';
  const maintenant = new Date();
  const secondes = Math.round((maintenant - d) / 1000);
  if(secondes < 60) return 'à l\'instant';
  const minutes = Math.round(secondes / 60);
  if(minutes < 60) return minutes + ' min';
  const heures = Math.round(minutes / 60);
  if(heures < 24) return heures + ' h';
  const jMaintenant = new Date(maintenant.getFullYear(), maintenant.getMonth(), maintenant.getDate());
  const jDate = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const jours = Math.round((jMaintenant - jDate) / 86400000);
  if(jours === 1) return 'hier';
  if(jours < 7) return jours + ' j';
  return d.toLocaleDateString('fr-CA', {day:'numeric', month:'short'});
};

/* ---- initiales pour avatar rond (messagerie) ---- */
window.cdInitiales = function(prenom, nom){
  const a = (prenom||'').trim().charAt(0);
  const b = (nom||'').trim().charAt(0);
  const ini = (a+b).toUpperCase();
  return ini || '?';
};

/* ---- langue courante (FR/EN) ----
   Persistée par le sélecteur de langue de l'accueil (localStorage 'cd-lang').
   Sert à faire suivre la langue de l'utilisateur dans les courriels de
   notification ET les textes de confirmation à l'écran, d'une page à l'autre.
   Défaut : 'fr'. */
window.cdLang = function(){
  try{
    const l = localStorage.getItem('cd-lang');
    if(l === 'fr' || l === 'en') return l;
  }catch(e){}
  return (document.documentElement.lang || '').toLowerCase() === 'en' ? 'en' : 'fr';
};

/* ---- choisir un texte selon la langue ----
   cdT('Bonjour', 'Hello')  → renvoie la variante FR ou EN.
   cdT({fr:'…', en:'…'})    → même chose à partir d'un objet.            */
window.cdT = function(fr, en){
  if(fr && typeof fr === 'object') return fr[cdLang()] != null ? fr[cdLang()] : (fr.fr || '');
  return cdLang() === 'en' ? (en != null ? en : fr) : fr;
};

/* applique la langue persistée dès le chargement (pages bilingues data-fr/data-en) */
(function appliquerLanguePersistee(){
  function poser(){
    let l; try{ l = localStorage.getItem('cd-lang'); }catch(e){}
    if(l !== 'en' && l !== 'fr') return;
    document.documentElement.lang = l;
    document.querySelectorAll('[data-fr]').forEach(el=>{
      if(el.dataset[l] != null) el.innerHTML = el.dataset[l];
    });
    /* placeholders (data-fr-ph / data-en-ph) et infobulles (data-fr-title / data-en-title) */
    document.querySelectorAll('[data-fr-ph]').forEach(el=>{
      const v = el.dataset[l==='en' ? 'enPh' : 'frPh']; if(v != null) el.placeholder = v;
    });
    document.querySelectorAll('[data-fr-title]').forEach(el=>{
      const v = el.dataset[l==='en' ? 'enTitle' : 'frTitle']; if(v != null) el.title = v;
    });
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', poser);
  else poser();
})();

/* sous-titre « Québec » sous le mot-symbole C-DIRECT (façon RE/MAX Québec :
   logo au-dessus, ville en dessous, plus petite et plus pâle) — posé sur
   TOUTES les pages qui chargent auth.js, visiteur anonyme ou connecté,
   donc placé ici plutôt que dans cdEnteteConnecte (qui exige une session).
   S'exécute avant cdEnteteConnecte (appelée plus tard par chaque page),
   qui peut ensuite envelopper .brand sans se soucier de ce détail. */
(function appliquerSousTitreMarque(){
  function poser(){
    const marque = document.querySelector('.topbar .brand');
    if(!marque || marque.querySelector('.brand-sous')) return;
    const noeudTexte = [...marque.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
    if(!noeudTexte) return;
    const pile = document.createElement('span');
    pile.style.cssText = 'display:flex;flex-direction:column;line-height:1.05';
    const ligneNom = document.createElement('span');
    ligneNom.textContent = noeudTexte.textContent.trim();
    const ligneVille = document.createElement('span');
    ligneVille.className = 'brand-sous';
    ligneVille.textContent = 'Québec';
    ligneVille.style.cssText = "font-family:'Instrument Sans',sans-serif;font-size:9px;font-weight:500;letter-spacing:.06em;color:var(--sourd,#5A6B63);margin-top:1px";
    pile.append(ligneNom, ligneVille);
    noeudTexte.replaceWith(pile);
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', poser);
  else poser();
})();

/* Salutation « Bienvenue [, Prénom] » juste après le mot-symbole, sur toutes
   les pages qui chargent auth.js. Visiteur anonyme = « Bienvenue » seul ;
   connecté = avec le prénom. Masquée sur mobile pour ne pas encombrer la barre.
   La bascule FR/EN recharge la page, donc cdT() au montage suffit. Admin ignoré
   (sa barre affiche déjà son nom et est dense). */
(function appliquerSalutation(){
  async function poser(){
    const marque = document.querySelector('.topbar .brand');
    if(!marque || document.getElementById('cd-salut')) return;
    let suffixe = '';
    try{
      const p = await cdProfil();
      if(p && p.role === 'admin') return;
      if(p && p.prenom) suffixe = ', ' + p.prenom;
    }catch(e){}
    if(document.getElementById('cd-salut')) return;
    if(!document.getElementById('cd-salut-style')){
      const st = document.createElement('style'); st.id = 'cd-salut-style';
      st.textContent = '#cd-salut{font-family:"Inter",sans-serif;font-size:14px;color:var(--sourd,#5A6B63);'+
        'border-left:1px solid var(--ligne,#E6E8E4);padding-left:12px;margin-left:2px;white-space:nowrap;flex:none}'+
        '@media(max-width:640px){#cd-salut{display:none}}';
      document.head.appendChild(st);
    }
    const s = document.createElement('span');
    s.id = 'cd-salut';
    s.textContent = cdT('Bienvenue', 'Welcome') + suffixe;
    marque.insertAdjacentElement('afterend', s);
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', poser);
  else poser();
})();
})();
