// =====================================================
// ASSISTANT.JS — Assistant IA C-Direct (chat texte)
// Charger APRÈS supabase-config.js et auth.js.
// - Lit avec la session de l'usager (RLS respectée)
// - Toute ACTION (publier, disponibilités…) exige une
//   confirmation explicite de l'usager (carte Confirmer)
// - Sans window.CD_CHAT_URL : mode aperçu (aucun appel IA)
// =====================================================
(function(){
'use strict';
if(!window.sbClient) return;
const sb = window.sbClient;
const URL_WORKER = (window.CD_CHAT_URL || '').replace(/\/+$/,'');

/* Mascotte : pharmacien C-Direct (SVG inline, aucune requête réseau) */
const MASCOTTE = '<svg viewBox="0 0 120 120" role="img" aria-label="Pharmacien C-Direct" xmlns="http://www.w3.org/2000/svg">'
+'<circle cx="60" cy="60" r="60" fill="#E7F1EB"/>'
+'<path d="M14 120 C14 86 34 72 60 72 C86 72 106 86 106 120 Z" fill="#FFFFFF"/>'
+'<path d="M60 78 C78 78 92 92 95 120 L25 120 C28 92 42 78 60 78 Z" fill="#F5F9F7"/>'
+'<path d="M60 74 L48 120 M60 74 L72 120" stroke="#DCE6E0" stroke-width="2" fill="none"/>'
+'<path d="M60 74 L50 86 L60 96 L70 86 Z" fill="#0B6E4F"/>'
+'<rect x="76" y="90" width="15" height="15" rx="2" fill="#0B6E4F"/>'
+'<path d="M83.5 93 v9 M79 97.5 h9" stroke="#fff" stroke-width="2"/>'
+'<path d="M52 64 h16 v10 c0 5 -16 5 -16 0 Z" fill="#E3AD82"/>'
+'<ellipse cx="34" cy="50" rx="8" ry="15" fill="#BFC3C4"/><ellipse cx="86" cy="50" rx="8" ry="15" fill="#BFC3C4"/>'
+'<circle cx="60" cy="48" r="26" fill="#F0C6A0"/>'
+'<circle cx="34" cy="50" r="5.5" fill="#F0C6A0"/><circle cx="86" cy="50" r="5.5" fill="#F0C6A0"/>'
+'<ellipse cx="52" cy="31" rx="9" ry="5" fill="#F7D6B4" opacity=".7"/>'
+'<path d="M44 41 q6 -4 12 0" stroke="#9A9EA0" stroke-width="2.4" fill="none" stroke-linecap="round"/>'
+'<path d="M64 41 q6 -4 12 0" stroke="#9A9EA0" stroke-width="2.4" fill="none" stroke-linecap="round"/>'
+'<circle cx="43" cy="56" r="5" fill="#F2A79C" opacity=".45"/><circle cx="77" cy="56" r="5" fill="#F2A79C" opacity=".45"/>'
+'<g stroke="#20463B" stroke-width="2.6" fill="rgba(255,255,255,.25)"><circle cx="49" cy="48" r="8.5"/><circle cx="71" cy="48" r="8.5"/></g>'
+'<path d="M57.5 48 h5 M40.5 46 l-7 -2 M79.5 46 l7 -2" stroke="#20463B" stroke-width="2.6" fill="none" stroke-linecap="round"/>'
+'<circle cx="49" cy="48.5" r="2.6" fill="#2B2B2B"/><circle cx="71" cy="48.5" r="2.6" fill="#2B2B2B"/>'
+'<path d="M60 53 q3 4 -1 6" stroke="#D79B72" stroke-width="2" fill="none" stroke-linecap="round"/>'
+'<path d="M47 62 Q60 59 73 62 Q65 69 60 66 Q55 69 47 62 Z" fill="#B9BCBE"/>'
+'<path d="M52 67 Q60 73 68 67" stroke="#B4715A" stroke-width="2" fill="none" stroke-linecap="round"/>'
+'</svg>';

let profil = null, ouvert = false, occupe = false;
let messages = [];          // historique format Anthropic
let attenteAction = null;   // {resolve} pendant une confirmation

/* ================= OUTILS — exécution locale =================
   Les LECTURES s'exécutent tout de suite; les ÉCRITURES passent
   par une carte de confirmation. Noms = définitions du Worker.  */
const ECRITURES = ['publier_quart','ajouter_disponibilites','retirer_disponibilites'];

function sous(o, cles){ const r={}; cles.forEach(k=>{ if(o && o[k]!==undefined && o[k]!==null) r[k]=o[k]; }); return r; }

const OUTILS = {
  async regles_reseau(){
    const { data } = await sb.from('regles_reseau').select('*').limit(1).maybeSingle();
    return data || {};
  },
  /* ---- pharmacien ---- */
  async chercher_quarts(a){
    const { data, error } = await sb.rpc('get_contrats_ouverts');
    if(error) return { erreur: error.message };
    let l = data || [];
    if(a.date_min) l = l.filter(k=>String(k.date_contrat)>=a.date_min);
    if(a.date_max) l = l.filter(k=>String(k.date_contrat)<=a.date_max);
    if(a.tarif_min) l = l.filter(k=>parseFloat(k.tarif_horaire)>=a.tarif_min);
    return l.slice(0,15).map(k=>sous(k,['numero_reference','date_contrat','heure_debut','heure_fin','tarif_horaire','pharmacie_nom','ville','code_postal','distance_km','seul_pharmacien','atp_presente','notes']));
  },
  async mes_mandats(){
    const { data, error } = await sb.rpc('get_mes_mandats');
    if(error) return { erreur: error.message };
    return (data||[]).slice(0,25).map(m=>sous(m,['numero_reference','date_contrat','heure_debut','heure_fin','tarif_horaire','statut','pharmacie_nom','total']));
  },
  async mes_stats(){
    const r = {};
    try{ const { data } = await sb.rpc('get_stats_pharmacien'); r.stats = data; }catch(e){}
    return r;
  },
  async mes_disponibilites(){
    const { data, error } = await sb.from('disponibilites').select('date_dispo').eq('pharmacien_id', profil.id).order('date_dispo');
    if(error) return { erreur: error.message };
    return (data||[]).map(d=>String(d.date_dispo).slice(0,10));
  },
  async ajouter_disponibilites(a){
    const dates = (a.dates||[]).filter(d=>/^\d{4}-\d{2}-\d{2}$/.test(d));
    const res = [];
    for(const d of dates){
      const { error } = await sb.from('disponibilites').insert({ pharmacien_id: profil.id, date_dispo: d });
      res.push({ date:d, ok: !error || error.code==='23505' });
    }
    return res;
  },
  async retirer_disponibilites(a){
    const dates = (a.dates||[]).filter(d=>/^\d{4}-\d{2}-\d{2}$/.test(d));
    const res = [];
    for(const d of dates){
      const { error } = await sb.from('disponibilites').delete().eq('pharmacien_id', profil.id).eq('date_dispo', d);
      res.push({ date:d, ok: !error });
    }
    return res;
  },
  /* ---- pharmacie ---- */
  async mes_contrats(){
    const { data, error } = await sb.from('contrats').select('numero_reference,date_contrat,heure_debut,heure_fin,tarif_horaire,statut,created_at').eq('pharmacie_id', profil.id).order('created_at',{ascending:false}).limit(25);
    if(error) return { erreur: error.message };
    return data || [];
  },
  async voir_candidats(a){
    const { data: k } = await sb.from('contrats').select('id').eq('pharmacie_id', profil.id).eq('numero_reference', a.ref).maybeSingle();
    if(!k) return { erreur: 'Contrat introuvable : ' + a.ref };
    const { data, error } = await sb.rpc('get_candidats', { p_contrat: k.id });
    if(error) return { erreur: error.message };
    return (data||[]).map(c=>sous(c,['prenom','nom','statut','tarif_propose','heure_debut','heure_fin','note_moyenne','nb_evaluations','message_texte']));
  },
  async compter_compatibles(a){
    const { data, error } = await sb.rpc('compter_compatibles', { p_date: a.date, p_tarif: a.tarif });
    return error ? { erreur: error.message } : { compatibles: data };
  },
  async mes_factures(){
    const { data, error } = await sb.rpc('get_factures');
    if(error) return { erreur: error.message };
    return (data||[]).filter(f=>f.pharmacie_id===profil.id && f.statut!=='brouillon').slice(0,25)
      .map(f=>sous(f,['numero_facture','numero_reference','total','statut','date_echeance','pharmacien_prenom','pharmacien_nom']));
  },
  async publier_quart(a){
    const { data: regles } = await sb.from('regles_reseau').select('*').limit(1).maybeSingle();
    const plancher = regles && parseFloat(regles.tarif_horaire_minimum);
    const tarif = parseFloat(a.tarif_horaire);
    if(plancher && tarif < plancher) return { erreur: 'Tarif sous le plancher du réseau ('+plancher+' $/h).' };
    if(!a.date_contrat || !a.heure_debut || !a.heure_fin || a.heure_fin <= a.heure_debut)
      return { erreur: 'Date ou heures invalides (la fin doit suivre le début).' };
    const { data, error } = await sb.from('contrats').insert({
      pharmacie_id: profil.id,
      date_contrat: a.date_contrat,
      heure_debut: a.heure_debut,
      heure_fin: a.heure_fin,
      tarif_horaire: tarif,
      rx_jour_semaine: a.rx_jour_semaine || null,
      rx_jour_weekend: a.rx_jour_weekend || null,
      seul_pharmacien: !!a.seul_pharmacien,
      atp_presente: !!a.atp_presente,
      services: a.services || [],
      notes: a.notes || null
    }).select('numero_reference').single();
    if(error) return { erreur: error.message };
    try{ window.cdDiffuserContrat && cdDiffuserContrat(data.numero_reference); }catch(e){}
    return { ok: true, numero_reference: data.numero_reference, sms: 'diffusion lancée aux pharmaciens compatibles' };
  }
};

/* résumé humain d'une écriture, pour la carte de confirmation */
function resumeAction(nom, a){
  if(nom==='publier_quart')
    return 'Publier un quart — ' + a.date_contrat + ', ' + (a.heure_debut||'') + ' à ' + (a.heure_fin||'') +
           ', ' + a.tarif_horaire + ' $/h' + (a.notes ? ' — ' + a.notes : '') +
           '. Les pharmaciens compatibles seront avisés par SMS.';
  if(nom==='ajouter_disponibilites') return 'Marquer disponible : ' + (a.dates||[]).join(', ');
  if(nom==='retirer_disponibilites') return 'Retirer les disponibilités : ' + (a.dates||[]).join(', ');
  return nom + ' ' + JSON.stringify(a);
}

/* ================= UI ================= */
const css = `
#cda-btn{position:fixed;right:20px;bottom:20px;z-index:9990;width:60px;height:60px;border-radius:50%;
  background:#E7F1EB;border:2px solid #0D2B24;cursor:pointer;box-shadow:0 6px 24px rgba(13,43,36,.35);
  padding:0;overflow:hidden;display:flex;align-items:center;justify-content:center;transition:transform .15s}
#cda-btn:hover{transform:scale(1.06)}
#cda-btn svg{width:100%;height:100%;display:block}
.cda-ava{width:40px;height:40px;border-radius:50%;overflow:hidden;flex:0 0 auto;background:#E7F1EB}
.cda-ava svg{width:100%;height:100%;display:block}
.cda-ligne-ia{display:flex;gap:8px;align-items:flex-end}
.cda-ligne-ia .cda-ava{width:30px;height:30px;margin-bottom:2px}
#cda-panel{position:fixed;right:20px;bottom:88px;z-index:9991;width:min(380px,calc(100vw - 24px));
  height:min(560px,calc(100vh - 120px));background:#fff;border:1px solid rgba(13,43,36,.12);border-radius:16px;
  box-shadow:0 16px 48px rgba(13,43,36,.22);display:none;flex-direction:column;overflow:hidden;
  font-family:Inter,-apple-system,'Segoe UI',Roboto,sans-serif}
#cda-panel.ouvert{display:flex}
.cda-tete{background:#0D2B24;color:#FAFAF7;padding:14px 16px;display:flex;align-items:center;gap:10px}
.cda-tete b{font-size:14px;letter-spacing:.02em}
.cda-tete small{opacity:.65;font-size:11px;display:block}
.cda-fermer{margin-left:auto;background:none;border:none;color:#FAFAF7;opacity:.7;cursor:pointer;font-size:18px}
.cda-corps{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:10px;background:#FAFAF7}
.cda-msg{max-width:85%;padding:10px 13px;border-radius:14px;font-size:13.5px;line-height:1.45;white-space:pre-wrap;word-wrap:break-word}
.cda-msg.moi{align-self:flex-end;background:#0D2B24;color:#FAFAF7;border-bottom-right-radius:4px}
.cda-msg.ia{align-self:flex-start;background:#fff;border:1px solid rgba(13,43,36,.1);border-bottom-left-radius:4px;color:#1b2b26}
.cda-msg.ia a{color:#0D2B24;font-weight:600}
.cda-carte{align-self:stretch;background:#fff;border:1px solid #C98A2B;border-radius:12px;padding:12px}
.cda-carte .titre{font-size:11px;font-weight:700;letter-spacing:.08em;color:#C98A2B;text-transform:uppercase;margin-bottom:6px}
.cda-carte .det{font-size:13px;color:#1b2b26;line-height:1.5;margin-bottom:10px}
.cda-carte .boutons{display:flex;gap:8px}
.cda-carte button{flex:1;padding:9px 0;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer}
.cda-ok{background:#0D2B24;color:#FAFAF7;border:none}
.cda-non{background:none;border:1px solid rgba(13,43,36,.25);color:#1b2b26}
.cda-carte.faite .boutons{display:none}
.cda-carte .etat{font-size:12px;font-weight:600;margin-top:2px}
.cda-saisie{display:flex;gap:8px;padding:12px;border-top:1px solid rgba(13,43,36,.08);background:#fff}
.cda-saisie textarea{flex:1;resize:none;border:1px solid rgba(13,43,36,.18);border-radius:10px;padding:9px 12px;
  font:13.5px Inter,-apple-system,sans-serif;height:40px;outline:none}
.cda-saisie textarea:focus{border-color:#0D2B24}
.cda-envoyer{background:#C98A2B;border:none;border-radius:10px;width:44px;cursor:pointer;color:#fff;font-size:16px}
.cda-envoyer:disabled{opacity:.5;cursor:default}
.cda-note{font-size:11px;color:#6b7b76;text-align:center;padding:0 12px 8px;background:#fff}
.cda-apercu{background:#FFF7EA;border-bottom:1px solid #C98A2B;color:#7a5310;font-size:12px;padding:8px 14px;line-height:1.4}
.cda-tape{align-self:flex-start;color:#6b7b76;font-size:12px;padding:2px 6px}
@media (max-width:480px){#cda-panel{right:8px;left:8px;width:auto;bottom:80px}}
`;

function el(tag, cls, txt){ const e=document.createElement(tag); if(cls) e.className=cls; if(txt!==undefined) e.textContent=txt; return e; }
let corps, saisie, btnEnvoyer;

function ajouterMsg(qui, texte){
  const m = el('div','cda-msg '+qui, texte);
  corps.appendChild(m); corps.scrollTop = corps.scrollHeight;
  return m;
}

function carteConfirmation(nom, args){
  return new Promise(resolve=>{
    const c = el('div','cda-carte');
    c.appendChild(el('div','titre','Confirmation requise'));
    c.appendChild(el('div','det', resumeAction(nom, args)));
    const b = el('div','boutons');
    const ok = el('button','cda-ok','Confirmer');
    const non = el('button','cda-non','Annuler');
    b.append(ok, non); c.appendChild(b);
    const etat = el('div','etat',''); c.appendChild(etat);
    corps.appendChild(c); corps.scrollTop = corps.scrollHeight;
    ok.onclick = ()=>{ c.classList.add('faite'); etat.textContent='Confirmé — exécution…'; etat.style.color='#0D2B24'; resolve({ go:true, etat }); };
    non.onclick = ()=>{ c.classList.add('faite'); etat.textContent='Annulé.'; etat.style.color='#a33'; resolve({ go:false, etat }); };
    attenteAction = { annuler: ()=>{ c.classList.add('faite'); etat.textContent='Annulé.'; resolve({ go:false, etat }); } };
  });
}

/* ================= boucle de conversation ================= */
async function envoyer(){
  const t = saisie.value.trim();
  if(!t || occupe) return;
  saisie.value=''; ajouterMsg('moi', t);
  if(!URL_WORKER){
    ajouterMsg('ia', "Mode aperçu — l'assistant sera activé très bientôt. Je pourrai alors chercher des quarts, gérer vos disponibilités ou publier un contrat pour vous (toujours avec votre confirmation avant d'agir).");
    return;
  }
  messages.push({ role:'user', content: t });
  await tourIA();
}

async function tourIA(){
  occupe = true; btnEnvoyer.disabled = true;
  const tape = el('div','cda-tape','L\'assistant réfléchit…');
  corps.appendChild(tape); corps.scrollTop = corps.scrollHeight;
  try{
    const s = await cdSession();
    const rep = await fetch(URL_WORKER + '/chat', {
      method:'POST',
      headers:{ 'Content-Type':'application/json', 'Authorization':'Bearer ' + (s && s.access_token || '') },
      body: JSON.stringify({ role: profil.role, messages: messages })
    });
    tape.remove();
    if(!rep.ok){
      const e = await rep.text();
      ajouterMsg('ia', rep.status===503 ? "L'assistant n'est pas encore activé (clé API manquante)." : 'Erreur de l\'assistant ('+rep.status+').');
      console.error('assistant:', e); occupe=false; btnEnvoyer.disabled=false; return;
    }
    const data = await rep.json();
    messages.push({ role:'assistant', content: data.content });
    let resultats = [];
    for(const bloc of data.content){
      if(bloc.type==='text' && bloc.text.trim()) ajouterMsg('ia', bloc.text.trim());
      if(bloc.type==='tool_use'){
        let contenu;
        if(ECRITURES.includes(bloc.name)){
          const { go, etat } = await carteConfirmation(bloc.name, bloc.input);
          attenteAction = null;
          if(go){
            const r = await OUTILS[bloc.name](bloc.input || {});
            const ok = !(r && r.erreur);
            etat.textContent = ok ? 'Fait ✓' + (r.numero_reference ? ' — ' + r.numero_reference : '') : 'Erreur : ' + r.erreur;
            etat.style.color = ok ? '#12a96e' : '#a33';
            contenu = JSON.stringify(r);
          } else {
            contenu = JSON.stringify({ annule: true, note: "L'usager a annulé l'action." });
          }
        } else {
          const fn = OUTILS[bloc.name];
          const r = fn ? await fn(bloc.input || {}) : { erreur: 'Outil inconnu.' };
          contenu = JSON.stringify(r);
        }
        resultats.push({ type:'tool_result', tool_use_id: bloc.id, content: contenu });
      }
    }
    occupe = false; btnEnvoyer.disabled = false;
    if(resultats.length){
      messages.push({ role:'user', content: resultats });
      if(messages.length < 60) await tourIA();   // garde-fou anti-boucle
    }
  }catch(e){
    tape.remove();
    ajouterMsg('ia', 'Connexion impossible. Réessayez dans un instant.');
    console.error('assistant:', e);
    occupe = false; btnEnvoyer.disabled = false;
  }
}

/* ================= montage ================= */
async function monter(){
  try{ profil = await cdProfil(); }catch(e){ return; }
  if(!profil || profil.approuve !== true) return;
  if(profil.role !== 'pharmacien' && profil.role !== 'pharmacie') return;

  const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);

  const btn = el('button','', ''); btn.id='cda-btn'; btn.title='Assistant C-Direct'; btn.innerHTML=MASCOTTE;
  btn.setAttribute('aria-label','Ouvrir l\'assistant C-Direct');
  const panel = el('div',''); panel.id='cda-panel';

  const tete = el('div','cda-tete');
  const avaTete = el('div','cda-ava'); avaTete.innerHTML = MASCOTTE;
  const bloc = el('div','');
  bloc.appendChild(el('b','', 'Assistant C-Direct'));
  bloc.appendChild(el('small','', profil.role==='pharmacie' ? 'Publier, comparer, suivre — en une phrase' : 'Trouver des quarts, gérer vos dispos — en une phrase'));
  const fermer = el('button','cda-fermer','×'); fermer.onclick=()=>{ panel.classList.remove('ouvert'); };
  tete.append(avaTete, bloc, fermer);

  corps = el('div','cda-corps');
  const pied = el('div','cda-saisie');
  saisie = document.createElement('textarea');
  saisie.placeholder = profil.role==='pharmacie' ? 'Ex. : Publie un quart samedi 9 h à 17 h à 85 $/h' : 'Ex. : Des quarts à plus de 80 $/h cette semaine?';
  saisie.addEventListener('keydown', e=>{ if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); envoyer(); } });
  btnEnvoyer = el('button','cda-envoyer','➤'); btnEnvoyer.onclick = envoyer;
  pied.append(saisie, btnEnvoyer);
  const note = el('div','cda-note','Les actions (publication, disponibilités…) exigent toujours votre confirmation.');

  panel.append(tete);
  if(!URL_WORKER) panel.appendChild(el('div','cda-apercu','Mode aperçu — l\'intelligence de l\'assistant sera branchée sous peu. L\'interface est fonctionnelle.'));
  panel.append(corps, note, pied);

  btn.onclick = ()=>{
    ouvert = !panel.classList.contains('ouvert');
    panel.classList.toggle('ouvert', ouvert);
    if(ouvert && !corps.childElementCount){
      const ligne = el('div','cda-ligne-ia');
      const ava = el('div','cda-ava'); ava.innerHTML = MASCOTTE;
      const bulle = el('div','cda-msg ia', 'Bonjour ' + (profil.prenom || '') + '! ' + (profil.role==='pharmacie'
        ? 'Je peux publier un quart, compter les pharmaciens compatibles, résumer vos candidatures ou vos factures. Dites-le simplement.'
        : 'Je peux chercher des quarts selon vos critères, gérer vos disponibilités ou résumer vos mandats et revenus. Dites-le simplement.'));
      ligne.append(ava, bulle); corps.appendChild(ligne); corps.scrollTop = corps.scrollHeight;
    }
    if(ouvert) saisie.focus();
  };

  document.body.append(btn, panel);
}

if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', monter);
else monter();
})();
