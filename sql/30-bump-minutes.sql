-- =====================================================================
-- C-DIRECT · SQL 30 — MAJORATION AUTO : PALIERS EN MINUTES (15/30/45/60…)
--   Avant : l'intervalle de la majoration automatique du tarif ne pouvait
--   être exprimé qu'en heures entières (bump_intervalle_h, min. 1 h).
--   Après : la pharmacie peut choisir 15 min / 30 min / 45 min / 1 h et au-
--   delà (bump_intervalle_min, en minutes), jusqu'à 7 jours (10 080 min).
--
-- À exécuter dans Supabase → SQL Editor, APRÈS 29.
-- Idempotent (add column if not exists / drop+recreate constraint).
-- Défensif : reprend les valeurs existantes (heures -> minutes), ne perd
-- aucune configuration déjà enregistrée par une pharmacie.
-- =====================================================================

-- 1) Nouvelle colonne : intervalle en minutes
alter table public.profiles
  add column if not exists bump_intervalle_min int;  -- toutes les N minutes (15/30/45/60/...)

-- 2) Reprise des anciennes valeurs (heures -> minutes)
update public.profiles
   set bump_intervalle_min = bump_intervalle_h * 60
 where bump_intervalle_min is null
   and bump_intervalle_h is not null;

comment on column public.profiles.bump_intervalle_h is
  'Obsolète depuis SQL 30 — conservée pour compatibilité descendante. Utiliser bump_intervalle_min.';
comment on column public.profiles.bump_intervalle_min is
  'Majoration auto : applique un palier toutes les N minutes (15, 30, 45, 60, ... jusqu''à 10080 = 7 jours).';

-- 3) Garde-fous de cohérence : 15 min minimum, 7 jours (10 080 min) max
do $$
begin
  if exists (select 1 from pg_constraint where conname = 'profiles_bump_coherent') then
    alter table public.profiles drop constraint profiles_bump_coherent;
  end if;
  alter table public.profiles add constraint profiles_bump_coherent check (
    bump_actif = false
    or (bump_increment > 0 and bump_increment <= 50
        and bump_intervalle_min >= 15 and bump_intervalle_min <= 10080
        and bump_max > 0 and bump_max <= 500)
  );
end $$;

-- ---------------------------------------------------------------------
-- appliquer_hausses_auto — bascule sur make_interval(mins => ...)
-- ---------------------------------------------------------------------
create or replace function public.appliquer_hausses_auto()
returns TABLE (contrat_id uuid, numero_reference text, ancien numeric, nouveau numeric)
language plpgsql security definer set search_path = public
as $$
begin
  return query
  with candidats as (
    select k.id,
           k.numero_reference,
           k.tarif_horaire as ancien,
           p.bump_increment,
           p.bump_max,
           least(k.tarif_horaire + p.bump_increment, p.bump_max) as nouveau
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
       and k.date_contrat >= current_date
       and p.bump_actif = true
       and p.bump_increment is not null
       and p.bump_intervalle_min is not null
       and p.bump_max is not null
       and k.tarif_horaire < p.bump_max
       and now() - coalesce(k.derniere_hausse, k.created_at)
           >= make_interval(mins => p.bump_intervalle_min)
  ), maj as (
    update public.contrats k
       set tarif_initial   = coalesce(k.tarif_initial, k.tarif_horaire),
           tarif_horaire   = c.nouveau,
           derniere_hausse = now(),
           nb_hausses      = k.nb_hausses + 1
      from candidats c
     where k.id = c.id
       and c.nouveau > c.ancien
    returning k.id, k.numero_reference, c.ancien, k.tarif_horaire
  )
  select * from maj;
end;
$$;
revoke all on function public.appliquer_hausses_auto() from public, anon;
grant execute on function public.appliquer_hausses_auto() to authenticated;

-- 4) Cron : toutes les heures -> toutes les 15 minutes (sinon un palier de
--    15/30/45 min configuré par la pharmacie n'aurait aucun effet réel).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('c-direct-hausses-auto')
      where exists (select 1 from cron.job where jobname = 'c-direct-hausses-auto');
    perform cron.schedule('c-direct-hausses-auto', '*/15 * * * *',
                          $cron$select public.appliquer_hausses_auto();$cron$);
  end if;
end $$;
