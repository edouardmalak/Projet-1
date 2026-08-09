-- =====================================================================
-- C-DIRECT · SQL 63 — Durcissement ACL : retire l'accès ANONYME aux
-- fonctions restées exécutables par « public ».
--
-- CONTEXTE (audit du 2026-08-09) : dans Postgres, toute nouvelle
-- fonction est exécutable par PUBLIC par défaut, et un
-- DROP + CREATE remet ce défaut (contrairement à CREATE OR REPLACE qui
-- conserve les droits). Plusieurs fonctions n'ont donc jamais été
-- retirées à `anon`. Vérifié en direct avec la clé publishable, SANS
-- session :
--   · get_stats_pharmacien(uuid)  → répond (stats agrégées de n'importe
--     quel profil si on connaît/devine son uuid) ;
--   · get_note_profil(uuid)       → répond (moyenne d'évaluations).
-- Fuite limitée (agrégats, uuid non énumérables) mais à fermer, et
-- appliquer_indemnites() — qui modifie les données sans vérifier
-- auth.uid() — ne doit surtout pas rester exécutable par anon.
--
-- PRINCIPE : on retire public + anon, on conserve authenticated
-- (les politiques RLS et les pages utilisent ces fonctions avec la
-- session de l'usager — révoquer authenticated casserait le site).
-- Les fonctions internes appelées PAR d'autres fonctions security
-- definer continuent de marcher : elles s'exécutent avec les droits du
-- propriétaire.
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

-- Helpers RLS / rôle (auth.uid()-dépendants — inoffensifs mais fermés
-- par principe)
revoke execute on function public.a_postule(uuid) from public, anon;
grant  execute on function public.a_postule(uuid) to authenticated;
revoke execute on function public.contrat_de_ma_pharmacie(uuid) from public, anon;
grant  execute on function public.contrat_de_ma_pharmacie(uuid) to authenticated;
revoke execute on function public.contrat_est_ouvert(uuid) from public, anon;
grant  execute on function public.contrat_est_ouvert(uuid) to authenticated;
revoke execute on function public.est_admin() from public, anon;
grant  execute on function public.est_admin() to authenticated;
revoke execute on function public.est_approuve() from public, anon;
grant  execute on function public.est_approuve() to authenticated;
revoke execute on function public.est_partie_contrat(uuid) from public, anon;
grant  execute on function public.est_partie_contrat(uuid) to authenticated;
revoke execute on function public.eval_contrat_revele(uuid) from public, anon;
grant  execute on function public.eval_contrat_revele(uuid) to authenticated;
revoke execute on function public.mon_role() from public, anon;
grant  execute on function public.mon_role() to authenticated;
revoke execute on function public.partie_de_la_facture(uuid) from public, anon;
grant  execute on function public.partie_de_la_facture(uuid) to authenticated;

-- Utilitaires distance / jalons (pas de données sensibles, fermés par
-- principe)
revoke execute on function public.cd_distance_km(text, text) from public, anon;
grant  execute on function public.cd_distance_km(text, text) to authenticated;
revoke execute on function public.cd_fsa(text) from public, anon;
grant  execute on function public.cd_fsa(text) to authenticated;
revoke execute on function public.ajouter_jalon(text, jsonb) from public, anon;
grant  execute on function public.ajouter_jalon(text, jsonb) to authenticated;

-- ⚠ MUTATEUR interne sans vérification auth.uid() — le plus important
-- du lot. Personne d'autre que les fonctions security definer (qui
-- s'exécutent en propriétaire) n'a besoin de l'appeler.
revoke execute on function public.appliquer_indemnites(uuid, numeric, uuid) from public, anon, authenticated;

-- RPC de données — vérifiées fuyantes en anonyme (get_stats_pharmacien,
-- get_note_profil) ou re-vérifiant auth.uid() en interne (les autres) :
revoke execute on function public.get_stats_pharmacien(uuid) from public, anon;
grant  execute on function public.get_stats_pharmacien(uuid) to authenticated;
revoke execute on function public.get_note_profil(uuid) from public, anon;
grant  execute on function public.get_note_profil(uuid) to authenticated;
revoke execute on function public.get_evaluations_a_faire() from public, anon;
grant  execute on function public.get_evaluations_a_faire() to authenticated;
revoke execute on function public.get_evaluations_recues() from public, anon;
grant  execute on function public.get_evaluations_recues() to authenticated;
revoke execute on function public.get_fiabilite_a_faire() from public, anon;
grant  execute on function public.get_fiabilite_a_faire() to authenticated;
revoke execute on function public.get_fiabilite_pharmacie(uuid) from public, anon;
grant  execute on function public.get_fiabilite_pharmacie(uuid) to authenticated;

-- RPC d'écriture (re-vérifient auth.uid() en interne — ceinture et
-- bretelles)
revoke execute on function public.declarer_retard(uuid, time, text) from public, anon;
grant  execute on function public.declarer_retard(uuid, time, text) to authenticated;
revoke execute on function public.soumettre_evaluation(uuid, int, boolean, text) from public, anon;
grant  execute on function public.soumettre_evaluation(uuid, int, boolean, text) to authenticated;
revoke execute on function public.soumettre_fiabilite(uuid, int, boolean, boolean, text) from public, anon;
grant  execute on function public.soumettre_fiabilite(uuid, int, boolean, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution (les 2 fuites confirmées doivent être
-- fermées) — dans un navigateur SANS session, ces URL doivent répondre
-- 401/permission denied au lieu de données :
--   /rest/v1/rpc/get_stats_pharmacien?p_profil=00000000-0000-0000-0000-000000000000
--   /rest/v1/rpc/get_note_profil?p_profil=00000000-0000-0000-0000-000000000000
-- Et vérifier que le site connecté fonctionne toujours : profil.html
-- (stats + note), evaluations.html, mes-mandats.html (déclarer un
-- retard), fiche pharmacie (fiabilité).
-- ---------------------------------------------------------------------
