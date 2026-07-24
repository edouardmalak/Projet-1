// =====================================================
// AUTH.JS — helpers de session C-Direct (Supabase)
// Charger après supabase-config.js sur chaque page.
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

/* ---- diffusion SMS d'un nouveau contrat (site → Worker, comme cdConfirmerContrat) ---- */
window.cdDiffuserContrat = function(ref){
  if(!ref) return;
  cdSession().then(function(s){
    var token = s && s.access_token;
    if(!token) return;
    fetch('https://c-direct-sms.edouardmalak.workers.dev/diffuser', {
      method:'POST',
      headers:{ 'Content-Type':'application/json', 'Authorization':'Bearer '+token },
      body: JSON.stringify({ ref: ref })
    }).catch(function(){});
  }).catch(function(){});
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
   Remplace les flèches « ← Retour » par un menu horizontal persistant
   (comme un vrai bandeau de navigation). Injecté juste sous la topbar sur
   toutes les pages connectées. Bilingue (suit cdLang), surligne la page
   courante, masque les anciens liens « retour » devenus redondants.       */
const CD_MENUS = {
  pharmacien: [
    ['/contrats.html',           'Contrats',         'Contracts'],
    ['/mes-mandats.html',        'Mes mandats',      'My mandates'],
    ['/disponibilites.html',     'Disponibilités',   'Availability'],
    ['/messages.html',           'Messages',         'Messages'],
    ['/evaluations.html',        'Évaluations',      'Reviews'],
    ['/profil.html',             'Profil',           'Profile'],
    ['/faq.html',                'FAQ',              'FAQ']
  ],
  pharmacie: [
    ['/espace-pharmacie.html',   'Accueil',          'Home'],
    ['/demande.html',            'Nouvelle demande', 'New request'],
    ['/calendrier-pharmacie.html','Calendrier',      'Calendar'],
    ['/messages.html',           'Messages',         'Messages'],
    ['/evaluations.html',        'Évaluations',      'Reviews'],
    ['/profil.html',             'Profil',           'Profile'],
    ['/faq.html',                'FAQ',              'FAQ']
  ],
  admin: [
    ['/admin.html',              'Console',          'Console'],
    ['/nouveaux.html',           'Contrats',         'Contracts'],
    ['/pharmacies.html',         'Pharmaciens',      'Pharmacists'],
    ['/messages.html',           'Messages',         'Messages'],
    ['/evaluations.html',        'Évaluations',      'Reviews'],
    ['/profil.html',             'Profil',           'Profile'],
    ['/faq.html',                'FAQ',              'FAQ']
  ]
};
window.cdMenuRole = function(role){
  if(document.getElementById('cd-menu')) return;         // idempotent
  const items = CD_MENUS[role] || CD_MENUS.pharmacien;
  const en = cdLang() === 'en';
  const ici = (location.pathname || '/').replace(/\.html$/,'').replace(/\/+$/,'') || '/';

  const strip = document.createElement('nav');
  strip.id = 'cd-menu';
  strip.setAttribute('aria-label', en ? 'Main menu' : 'Menu principal');
  strip.style.cssText = 'display:flex;gap:2px;align-items:center;overflow-x:auto;'+
    'background:rgba(255,255,255,.94);border-bottom:1px solid var(--ligne,#e3e8e5);'+
    "padding:0 16px;height:46px;font-family:'IBM Plex Mono',monospace;-webkit-overflow-scrolling:touch";

  items.forEach(([href, fr, an])=>{
    const cle = href.replace(/\.html$/,'');
    const actif = ici === cle;
    const a = document.createElement('a');
    a.href = href;
    a.textContent = en ? an : fr;
    a.setAttribute('aria-current', actif ? 'page' : 'false');
    const couleur = actif ? 'var(--vert-vif,#0f8a5f)' : 'var(--sourd,#6b7772)';
    a.style.cssText = 'white-space:nowrap;text-decoration:none;font-size:11.5px;letter-spacing:.06em;'+
      'text-transform:uppercase;padding:8px 12px;border-radius:6px;color:'+couleur+';'+
      (actif ? 'background:rgba(16,138,95,.10);font-weight:700' : 'font-weight:500');
    if(!actif){
      a.addEventListener('mouseenter', ()=> a.style.color='var(--vert-vif,#0f8a5f)');
      a.addEventListener('mouseleave', ()=> a.style.color='var(--sourd,#6b7772)');
    }
    strip.appendChild(a);
  });

  const tb = document.querySelector('.topbar');
  if(tb && tb.parentNode) tb.parentNode.insertBefore(strip, tb.nextSibling);
  else document.body.insertBefore(strip, document.body.firstChild);

  // masquer les anciennes flèches « ← Retour » (le menu les remplace)
  document.querySelectorAll('.retour, a.retour, #lien-retour').forEach(el=>{ el.style.display = 'none'; });
};

/* ---- en-tête connecté : injecte « PRÉNOM · DÉCONNEXION » dans la topbar ---- */
window.cdEnteteConnecte = async function(){
  const p = await cdProfil();
  if(!p) return null;
  const conteneur = document.querySelector('.topbar .droite') ||
                    document.querySelector('.topbar .in') ||
                    document.querySelector('.topbar .wrap');
  if(conteneur){
    const el = document.createElement('span');
    el.id = 'cd-entete-session';
    el.style.cssText = "display:inline-flex;align-items:center;gap:10px;font-family:'IBM Plex Mono',monospace;font-size:11.5px;letter-spacing:.08em;text-transform:uppercase;white-space:nowrap";
    /* badge de rôle — on sait TOUJOURS avec quel compte on est connecté */
    const roleBadge = document.createElement('span');
    const libelles = { admin:'ADMIN', pharmacie:'PHARMACIE', pharmacien:'PHARMACIEN(NE)' };
    roleBadge.textContent = libelles[p.role] || p.role || '';
    roleBadge.style.cssText = 'padding:2px 8px;border-radius:3px;border:1px solid;font-size:10px;font-weight:700;letter-spacing:.1em;' +
      (p.role === 'admin'
        ? 'color:#E8B849;border-color:rgba(232,184,73,.55);background:rgba(232,184,73,.1)'
        : 'color:#17C980;border-color:rgba(23,201,128,.45);background:rgba(18,169,110,.1)');
    const nom = document.createElement('b');
    nom.textContent = p.prenom || p.courriel || '';
    const sep = document.createElement('span'); sep.textContent = '·'; sep.style.opacity = '.5';
    const btn = document.createElement('button');
    btn.textContent = cdT('Déconnexion', 'Log out');
    btn.style.cssText = "background:none;border:none;cursor:pointer;color:inherit;font:inherit;text-decoration:underline;text-underline-offset:3px;opacity:.8";
    btn.onclick = cdDeconnexion;
    el.append(roleBadge, nom, sep, btn);
    conteneur.appendChild(el);
    // masquer les liens Connexion/Inscription éventuels
    document.querySelectorAll('a[href^="acces.html"],a[href^="/acces.html"]').forEach(a=>{
      if(/mode=(conn|insc)/.test(a.getAttribute('href'))) a.style.display = 'none';
    });
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
