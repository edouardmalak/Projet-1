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
