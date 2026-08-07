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
  await sb.auth.signOut();
  _profil = null;
  location.href = '/index.html';
};

/* ---- menu de navigation selon le rôle ----
   Remplace les flèches « ← Retour » par un menu horizontal persistant,
   regroupé en menus déroulants pour ne pas aligner 9-10 liens à plat.
   Injecté juste sous la topbar sur toutes les pages connectées. Bilingue
   (suit cdLang), surligne la page courante (un groupe s'allume si l'une
   de ses entrées est active), masque les anciens liens « retour ».
   Format d'une entrée : soit un lien plat ['/href.html','FR','EN'],
   soit un groupe déroulant { g:'FR', ge:'EN', items:[[...],[...]] }.      */
const CD_MENUS = {
  pharmacien: [
    { g:'Contrats', ge:'Contracts', items: [
      ['/contrats.html',           'Trouver un contrat', 'Contracts'],
      ['/carte.html',              'Maps',             'Maps'],
      ['/mes-mandats.html',        'Mandats confirmés', 'My mandates']
    ]},
    ['/disponibilites.html',     'Calendrier',        'Calendar'],
    ['/messages.html',           'Clavardage',       'Messages'],
    { g:'Compte', ge:'Account', items: [
      ['/evaluations.html',        'Évaluations',      'Reviews'],
      ['/dispensaire.html',        'Dispensaire',       'Dispensary'],
      ['/profil.html',             'Profil',           'Profile'],
      ['/faq.html',                'FAQ',              'FAQ'],
      ['/parametres.html',         'Paramètres',       'Settings']
    ]}
  ],
  pharmacie: [
    { g:'Contrats', ge:'Contracts', items: [
      ['/espace-pharmacie.html',   'Accueil',          'Home'],
      /* Le vrai formulaire de publication vit dans espace-pharmacie.html.
         (L'ancien /demande.html est une page héritée : aucune connexion,
          aucune écriture en base — elle ne créait pas de contrat.) */
      ['/espace-pharmacie.html#nouvelle-demande', 'Nouvelle demande', 'New request'],
      ['/espace-pharmacie.html#mes-contrats', 'Mes contrats', 'My contracts'],
      ['/espace-pharmacie.html#factures-recues', 'Factures reçues', 'Invoices received']
    ]},
    ['/calendrier-pharmacie.html','Calendrier',      'Calendar'],
    ['/messages.html',           'Clavardage',       'Messages'],
    { g:'Compte', ge:'Account', items: [
      ['/evaluations.html',        'Évaluations',      'Reviews'],
      ['/dispensaire.html',        'Dispensaire',       'Dispensary'],
      ['/profil.html',             'Profil',           'Profile'],
      ['/faq.html',                'FAQ',              'FAQ'],
      ['/parametres.html',         'Paramètres',       'Settings']
    ]}
  ],
  admin: [
    ['/admin.html',              'Console',          'Console'],
    ['/admin-verification.html', 'Vérification',     'Verification'],
    ['/admin-shifts.html',       'Contrats',         'Contracts'],
    ['/admin-articles.html',     'Dispensaire',       'Dispensary'],
    ['/messages.html',           'Clavardage',       'Messages'],
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

  function creerLien(href, fr, an){
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

  items.forEach(entree=>{
    if(Array.isArray(entree)){
      strip.appendChild(creerLien(entree[0], entree[1], entree[2]));
      return;
    }
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

/* ---- en-tête connecté : injecte « NOM · ★ note · DÉCONNEXION » dans la topbar ----
   Le nom est celui du pharmacien(ne) OU de la pharmacie selon le rôle
   (nom_pharmacie, pas prénom, côté pharmacie). La réputation (étoiles +
   nombre d'avis, sql/19 get_note_profil) s'affiche à côté dès qu'elle
   existe — jamais pour l'admin, qui n'est pas noté. Les deux sont un lien
   vers /evaluations.html. */
window.cdEnteteConnecte = async function(){
  const p = await cdProfil();
  if(!p) return null;
  const conteneur = document.querySelector('.topbar .droite') ||
                    document.querySelector('.topbar .in') ||
                    document.querySelector('.topbar .wrap');
  if(conteneur){
    const el = document.createElement('span');
    el.id = 'cd-entete-session';
    el.style.cssText = "display:inline-flex;align-items:center;gap:10px;font-family:'IBM Plex Mono',monospace;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase;white-space:nowrap;flex:none";
    /* badge de rôle — on sait TOUJOURS avec quel compte on est connecté */
    const roleBadge = document.createElement('span');
    const libelles = { admin:'ADMIN', pharmacie:'PHARMACIE', pharmacien:'PHARMACIEN(NE)' };
    roleBadge.textContent = libelles[p.role] || p.role || '';
    roleBadge.style.cssText = 'padding:2px 8px;border-radius:3px;border:1px solid;font-size:10px;font-weight:700;letter-spacing:.1em;' +
      (p.role === 'admin'
        ? 'color:#E8B849;border-color:rgba(232,184,73,.55);background:rgba(232,184,73,.1)'
        : 'color:#17C980;border-color:rgba(23,201,128,.45);background:rgba(18,169,110,.1)');
    /* nom affiché — pharmacie : nom commercial ; pharmacien/admin : prénom */
    const nomAffiche = p.role === 'pharmacie'
      ? (p.nom_pharmacie || p.ville || p.courriel || '')
      : (p.prenom || p.courriel || '');
    const nom = document.createElement(p.role === 'admin' ? 'b' : 'a');
    nom.textContent = nomAffiche;
    nom.style.cssText = 'color:inherit;text-decoration:none;font-weight:700';
    if(p.role !== 'admin'){
      nom.href = '/evaluations.html';
      nom.addEventListener('mouseenter', ()=> nom.style.textDecoration='underline');
      nom.addEventListener('mouseleave', ()=> nom.style.textDecoration='none');
    }
    /* réputation — étoiles + nombre d'avis, cachée tant qu'aucune note
       n'existe (compte neuf) et jamais chargée pour l'admin */
    const etoiles = document.createElement('a');
    etoiles.href = '/evaluations.html';
    etoiles.style.cssText = 'display:none;color:var(--jaune,#C97B12);text-decoration:none;font-weight:600;letter-spacing:.02em';
    const sep = document.createElement('span'); sep.textContent = '·'; sep.style.opacity = '.5';
    const btn = document.createElement('button');
    btn.textContent = cdT('Déconnexion', 'Log out');
    btn.style.cssText = "background:none;border:none;cursor:pointer;color:inherit;font:inherit;text-decoration:underline;text-underline-offset:3px;opacity:.8";
    btn.onclick = cdDeconnexion;
    /* pas de badge « PHARMACIEN(NE) » à côté du nom du pharmacien —
       admin et pharmacie gardent le leur */
    if(p.role === 'pharmacien') el.append(nom, etoiles, sep, btn);
    else el.append(roleBadge, nom, etoiles, sep, btn);
    /* affiché juste à côté du logo C-Direct plutôt qu'à droite */
    const brand = document.querySelector('.topbar .brand');
    if(brand && brand.parentElement){
      const groupe = document.createElement('span');
      groupe.style.cssText = 'display:flex;align-items:center;gap:10px;min-width:0';
      brand.parentElement.insertBefore(groupe, brand);
      groupe.append(brand, el);
    } else {
      conteneur.appendChild(el);
    }
    // masquer les liens Connexion/Inscription éventuels
    document.querySelectorAll('a[href^="acces.html"],a[href^="/acces.html"]').forEach(a=>{
      if(/mode=(conn|insc)/.test(a.getAttribute('href'))) a.style.display = 'none';
    });
    /* réputation chargée en différé — n'attend pas ce résultat pour
       afficher le reste de l'en-tête */
    if(p.role === 'pharmacien' || p.role === 'pharmacie'){
      sb.rpc('get_note_profil', { p_profil: p.id }).then(({ data })=>{
        const n = data && data[0];
        if(n && n.nombre > 0){
          etoiles.textContent = '★ ' + Number(n.moyenne).toFixed(1) + ' (' + n.nombre + ')';
          etoiles.style.display = '';
        }
      }).catch(()=>{});
    }
  }
  if(p && p.role) cdMenuRole(p.role);
  return p;
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
window.cdArgent = n => new Intl.NumberFormat('fr-CA',{minimumFractionDigits:2,maximumFractionDigits:2}).format(n)+' $';
window.cdDate = d => new Date(d + (String(d).length===10 ? 'T12:00:00' : '')).toLocaleDateString('fr-CA',{weekday:'short',year:'numeric',month:'short',day:'numeric'});
window.cdHeure = h => String(h||'').slice(0,5).replace(':',' h ');

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
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', poser);
  else poser();
})();
})();
