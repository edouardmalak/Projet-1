-- =====================================================================
-- C-DIRECT · SQL 71 — AUTO-ACCEPTATION (JOB 1/2) · PLANIFICATION (pg_cron)
-- À exécuter APRÈS 70-auto-acceptation-moteur.sql.
--
-- Le repo utilise déjà pg_cron (sql/08, sql/30 : hausses-auto). Deux
-- tâches de plus :
--   · c-direct-matching : le séquenceur, toutes les 30 SECONDES
--     (syntaxe d'intervalle pg_cron ≥ 1.5 — Supabase est en 1.6+).
--     Le verrou consultatif du moteur garantit qu'une exécution lente
--     ne chevauche jamais la suivante.
--   · c-direct-rappel-calendrier : le 25 de chaque mois à 14h00 UTC
--     (≈ 9-10 h à Montréal) — UN push de rappel, pas une série.
--
-- Idempotent : dé-planifie avant de re-planifier.
-- =====================================================================

create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- dé-planification si déjà présent (idempotence)
    perform cron.unschedule(jobid)
      from cron.job
     where jobname in ('c-direct-matching', 'c-direct-rappel-calendrier');

    perform cron.schedule(
      'c-direct-matching',
      '30 seconds',
      $cron$ select public.traiter_file_matching(); $cron$);

    perform cron.schedule(
      'c-direct-rappel-calendrier',
      '0 14 25 * *',
      $cron$ select public.aa_rappel_calendrier(); $cron$);
  else
    raise notice 'pg_cron absent — activer l''extension (Database → Extensions) puis relancer ce fichier.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   select jobname, schedule, active from cron.job
--    where jobname like 'c-direct-%';
--   -> c-direct-matching · 30 seconds · t
--   -> c-direct-rappel-calendrier · 0 14 25 * * · t
--   (et c-direct-hausses-auto, déjà là depuis sql/30)
-- =====================================================================
