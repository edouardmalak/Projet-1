// =====================================================
// ACCUEIL-MASCOTTE.JS — greeter amical sur la page d'accueil
// Visiteur non connecté : la vraie IA exige une session, donc ici
// la mascotte oriente simplement (pharmacien / pharmacie / FAQ).
// Autonome, bilingue (data-fr/data-en → géré par setLang existant).
// =====================================================
(function(){
'use strict';

var MASCOTTE = '<svg viewBox="0 0 120 120" role="img" aria-label="Pharmacien C-Direct" xmlns="http://www.w3.org/2000/svg">'
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

var css = ''
+'#cdg-btn{position:fixed;right:20px;bottom:20px;z-index:40;width:62px;height:62px;border-radius:50%;'
+'background:#E7F1EB;border:2px solid #0B6E4F;cursor:pointer;box-shadow:0 6px 22px rgba(11,110,79,.3);'
+'padding:0;overflow:hidden;display:flex;align-items:center;justify-content:center;transition:transform .15s}'
+'#cdg-btn:hover{transform:scale(1.06)}#cdg-btn svg{width:100%;height:100%;display:block}'
+'#cdg-pastille{position:absolute;top:-3px;right:-3px;width:16px;height:16px;border-radius:50%;background:#C98A2B;'
+'border:2px solid #fff;animation:cdgpop 2s ease-in-out infinite}'
+'@keyframes cdgpop{0%,100%{transform:scale(1)}50%{transform:scale(1.25)}}'
+'#cdg-carte{position:fixed;right:20px;bottom:92px;z-index:41;width:min(320px,calc(100vw - 24px));'
+'background:#fff;border:1px solid rgba(11,110,79,.18);border-radius:16px;box-shadow:0 16px 44px rgba(8,38,28,.22);'
+'display:none;flex-direction:column;overflow:hidden;font-family:Inter,-apple-system,"Segoe UI",Roboto,sans-serif}'
+'#cdg-carte.on{display:flex}'
+'.cdg-tete{background:#0B6E4F;color:#fff;padding:14px 16px;display:flex;align-items:center;gap:10px}'
+'.cdg-ava{width:42px;height:42px;border-radius:50%;overflow:hidden;flex:0 0 auto;background:#E7F1EB}'
+'.cdg-ava svg{width:100%;height:100%;display:block}'
+'.cdg-tete b{font-size:15px;display:block}.cdg-tete small{opacity:.8;font-size:11.5px}'
+'.cdg-x{margin-left:auto;background:none;border:none;color:#fff;opacity:.8;cursor:pointer;font-size:20px;line-height:1}'
+'.cdg-corps{padding:14px 16px;color:#1B2622}'
+'.cdg-mot{font-size:13.5px;line-height:1.5;margin-bottom:12px}'
+'.cdg-corps button,.cdg-corps a.cdg-b{display:block;width:100%;text-align:left;box-sizing:border-box;'
+'padding:11px 14px;margin-bottom:8px;border-radius:10px;font:600 13.5px Inter,sans-serif;cursor:pointer;text-decoration:none}'
+'.cdg-plein{background:#0B6E4F;color:#fff;border:none}.cdg-plein:hover{background:#095c42}'
+'.cdg-vide{background:#fff;color:#0B6E4F;border:1px solid rgba(11,110,79,.4)}.cdg-vide:hover{background:#F1F7F4}'
+'.cdg-note{font-size:12px;color:#5A6B63;margin-top:4px;text-align:center}'
+'.cdg-note a{color:#0B6E4F;font-weight:600}'
+'@media(max-width:480px){#cdg-carte{right:8px;left:8px;width:auto}}';

function el(t,c){ var e=document.createElement(t); if(c) e.className=c; return e; }
function txt(node, fr, en){ node.setAttribute('data-fr',fr); node.setAttribute('data-en',en);
  var l = document.documentElement.lang==='en' ? en : fr; node.innerHTML = l; return node; }
function aller(r){ if(typeof window.allerAcces==='function') window.allerAcces(r);
  else window.location.href='acces.html?mode=insc&role='+r; }

function monter(){
  if(document.getElementById('cdg-btn')) return;
  var style=el('style'); style.textContent=css; document.head.appendChild(style);

  var btn=el('button'); btn.id='cdg-btn'; btn.title='C-Direct'; btn.setAttribute('aria-label','Ouvrir l\'accueil C-Direct');
  btn.innerHTML=MASCOTTE; var past=el('span'); past.id='cdg-pastille'; btn.appendChild(past);

  var carte=el('div'); carte.id='cdg-carte';
  var tete=el('div','cdg-tete');
  var ava=el('div','cdg-ava'); ava.innerHTML=MASCOTTE;
  var titre=el('div');
  var b=el('b'); txt(b,'Bienvenue chez C-Direct','Welcome to C-Direct');
  var s=el('small'); txt(s,'Le lien direct, 0 % commission','The direct link, 0% commission');
  titre.append(b,s);
  var x=el('button','cdg-x'); x.innerHTML='&times;'; x.onclick=function(){ carte.classList.remove('on'); };
  tete.append(ava,titre,x);

  var corps=el('div','cdg-corps');
  var mot=el('p','cdg-mot'); txt(mot,'Bonjour&nbsp;! Vous êtes… ?','Hello! You are…?');
  var bph=el('button','cdg-b cdg-plein'); txt(bph,'Je suis pharmacien remplaçant','I\'m a relief pharmacist'); bph.onclick=function(){ aller('pharmacien'); };
  var bpc=el('button','cdg-b cdg-plein'); txt(bpc,'Je suis une pharmacie','I\'m a pharmacy'); bpc.onclick=function(){ aller('pharmacie'); };
  var bfaq=el('a','cdg-b cdg-vide'); bfaq.href='#faq'; txt(bfaq,'Questions fréquentes','Frequently asked questions'); bfaq.onclick=function(){ carte.classList.remove('on'); };
  var note=el('div','cdg-note');
  txt(note,'Déjà membre&nbsp;? <a href="acces.html?mode=conn">Connectez-vous</a> pour l\'assistant.','Already a member? <a href="acces.html?mode=conn">Log in</a> for the assistant.');
  corps.append(mot,bph,bpc,bfaq,note);

  carte.append(tete,corps);
  btn.addEventListener('click',function(){ carte.classList.toggle('on'); past.style.display='none'; });
  document.body.append(btn,carte);
}

if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',monter);
else monter();
})();
