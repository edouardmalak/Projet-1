// =====================================================
// CONFIGURATION SUPABASE — C-Direct
// La clé « publishable » (anon) peut apparaître côté client :
// la sécurité repose sur les politiques RLS de la base.
// Toute logique nécessitant la clé service_role ira dans un
// Cloudflare Worker (phase future) — JAMAIS ici.
// Charger AVANT : https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2
// =====================================================
window.SB_URL = "https://fenlujjozanerbzyypjt.supabase.co";
window.SB_KEY = "sb_publishable_gl9B3gY9gHX2iG_aaPoJZw_N4-qePHn";
window.sbClient = window.supabase.createClient(window.SB_URL, window.SB_KEY);

// URL du Worker de l'assistant IA (c-direct-chat). Vide = mode aperçu
// (le widget s'affiche mais l'IA n'est pas branchée). À remplir après
// déploiement du Worker — voir workers/c-direct-chat/README.md.
window.CD_CHAT_URL = "https://c-direct-chat.edouardmalak.workers.dev";

// Identifiant client OAuth Google (synchronisation Google Agenda des
// disponibilités). Vide = bouton inactif, le calendrier fonctionne
// normalement sans. À créer dans Google Cloud Console — voir PRELANCEMENT.md.
window.CD_GOOGLE_CLIENT_ID = "";

// Connexion "Sign in with Apple". false = bouton "Continuer avec Apple"
// affiche un message local au lieu d'appeler Supabase (le fournisseur
// Apple n'y est pas encore activé — appeler quand même enverrait l'usager
// vers une page d'erreur Supabase brute). Passer à true seulement APRÈS
// avoir activé Apple dans Supabase → Authentication → Providers → Apple
// (Services ID / Team ID / Key du compte Apple Developer).
window.CD_APPLE_ENABLED = false;

// Clé publique VAPID (notifications Web Push — parametres.html). Vide =
// le bouton "Activer les notifications" affiche un message local au lieu
// d'appeler PushManager.subscribe(). À remplir après génération de la
// paire de clés VAPID (voir workers/c-direct-sms/README.md) — la clé
// PRIVÉE va en secret Worker (wrangler secret put VAPID_PRIVATE_KEY),
// jamais ici.
window.CD_VAPID_PUBLIC_KEY = "";
