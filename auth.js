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

/* ---- déconnexion ---- */
window.cdDeconnexion = async function(){
  await sb.auth.signOut();
  _profil = null;
  location.href = '/index.html';
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
    const nom = document.createElement('b');
    nom.textContent = p.prenom || p.courriel || '';
    const sep = document.createElement('span'); sep.textContent = '·'; sep.style.opacity = '.5';
    const btn = document.createElement('button');
    btn.textContent = 'Déconnexion';
    btn.style.cssText = "background:none;border:none;cursor:pointer;color:inherit;font:inherit;text-decoration:underline;text-underline-offset:3px;opacity:.8";
    btn.onclick = cdDeconnexion;
    el.append(nom, sep, btn);
    conteneur.appendChild(el);
    // masquer les liens Connexion/Inscription éventuels
    document.querySelectorAll('a[href^="acces.html"],a[href^="/acces.html"]').forEach(a=>{
      if(/mode=(conn|insc)/.test(a.getAttribute('href'))) a.style.display = 'none';
    });
  }
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
})();
