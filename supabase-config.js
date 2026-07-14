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
