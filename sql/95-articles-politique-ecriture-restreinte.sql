-- =====================================================================
-- C-DIRECT · SQL 95 — CORRECTIF DE sql/93 (dispensaire toujours invisible)
-- À exécuter dans Supabase → SQL Editor, APRÈS sql/94.
--
-- CE QUI CLOCHAIT
--   sql/93 a bien remplacé la politique de LECTURE, et le dispensaire est
--   resté invisible aux visiteurs déconnectés : toujours 401
--   « permission denied for function est_admin ».
--
--   La cause : sql/38 crée une SECONDE politique, articles_ecriture_admin,
--   déclarée `for all`. En PostgreSQL, `FOR ALL` couvre AUSSI le SELECT, et
--   celle-ci n'avait aucune clause `to`. Le rôle anon l'évaluait donc à
--   chaque lecture, se heurtait au refus d'EXECUTE sur est_admin(), et
--   toute la requête échouait — exactement le symptôme que sql/93 devait
--   supprimer. sql/93 avait retiré la mauvaise politique.
--
-- LE CORRECTIF : restreindre la politique d'écriture à `authenticated`.
--   Les droits eux-mêmes ne changent pas — seul l'admin écrit toujours —
--   mais anon ne l'évalue plus, donc ne touche plus est_admin().
--
-- Vérifié après exécution : GET /rest/v1/articles sans session répond 200
-- (il répondait 401), et aucun brouillon n'apparaît.
--
-- Idempotent. Annulation en fin de fichier.
-- =====================================================================

drop policy if exists articles_ecriture_admin on public.articles;
create policy articles_ecriture_admin on public.articles
  for all to authenticated
  using (public.est_admin()) with check (public.est_admin());

-- ---------------------------------------------------------------------
-- ANNULATION :
--   drop policy if exists articles_ecriture_admin on public.articles;
--   create policy articles_ecriture_admin on public.articles
--     for all using (public.est_admin()) with check (public.est_admin());
-- ---------------------------------------------------------------------
