-- =====================================================================
-- C-DIRECT · SQL 68 — AUTO-ACCEPTATION (JOB 1/2) · FONDATIONS
-- À exécuter dans Supabase → SQL Editor, APRÈS 67-entrevues-rendez-vous.sql.
--
-- Pose les tables et garde-fous du remplissage instantané :
--   · réglages admin (interrupteur maître, pause d'urgence, prime, plafond
--     horaire) + historique de chaque changement (qui, quand, ancien → nouveau)
--   · réglages du pharmacien (activation, filtres distance/heures/taux,
--     jours et périodes exclus)
--   · confirmations mensuelles de calendrier (fraîcheur des disponibilités)
--   · colonnes contrats : filled_via_auto_accept + premium_applied_per_hour
--   · GARANTIE ANTI-DOUBLE-RÉSERVATION au niveau BASE DE DONNÉES :
--     contrainte d'exclusion Postgres (btree_gist) — la base refuse tout
--     chevauchement de contrats acceptés pour un même pharmacien, quel que
--     soit le chemin de code.
--   · suivi des annulations de quarts auto-acceptés (contrôle d'abus 2/90j)
--   · file_notifications : push + courriel déclenchés par le moteur SQL,
--     livrés par le Worker c-direct-sms (cadence 1 min)
--
-- Idempotent. Aucune modification du code Stripe ni de la machine à états
-- des garanties de paiement.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Extension btree_gist — requise pour la contrainte d'exclusion
--    (égalité uuid dans un index gist).
-- ---------------------------------------------------------------------
create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 1) RÉGLAGES ADMIN (ligne unique id=1, même patron que regles_reseau)
--    feature_enabled  : interrupteur maître plateforme (défaut : ÉTEINT)
--    matching_paused  : BOUTON D'URGENCE — met le moteur en pause sans
--                       toucher aux réglages d'aucun pharmacien ; la file
--                       s'accumule et se vide à la reprise
--    premium_per_hour : prime CAD/h versée ENTIÈREMENT au pharmacien
--    max_auto_bookings_per_locum_per_hour : plafond de réservations
--                       automatiques par pharmacien par heure
--    Un changement ne s'applique qu'aux quarts RÉSERVÉS APRÈS (la prime
--    est photographiée sur le contrat au moment de la réservation —
--    jamais rétroactif, par construction).
-- ---------------------------------------------------------------------
create table if not exists public.auto_accept_admin_settings (
  id int primary key default 1 check (id = 1),
  feature_enabled boolean not null default false,
  matching_paused boolean not null default false,
  premium_per_hour numeric not null default 0 check (premium_per_hour >= 0),
  max_auto_bookings_per_locum_per_hour int not null default 3
    check (max_auto_bookings_per_locum_per_hour >= 1),
  updated_at timestamptz not null default now()
);
insert into public.auto_accept_admin_settings (id) values (1)
  on conflict (id) do nothing;

drop trigger if exists trg_aa_admin_updated on public.auto_accept_admin_settings;
create trigger trg_aa_admin_updated
  before update on public.auto_accept_admin_settings
  for each row execute function public.toucher_updated_at();

-- Historique : une ligne par champ modifié — qui, quand, ancien → nouveau.
create table if not exists public.auto_accept_admin_settings_history (
  id uuid primary key default gen_random_uuid(),
  modifie_par uuid references public.profiles(id) on delete set null,
  modifie_le timestamptz not null default now(),
  champ text not null,
  ancienne_valeur text,
  nouvelle_valeur text
);

create or replace function public.aa_journaliser_reglages_admin()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.feature_enabled is distinct from old.feature_enabled then
    insert into public.auto_accept_admin_settings_history (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'feature_enabled', old.feature_enabled::text, new.feature_enabled::text);
  end if;
  if new.matching_paused is distinct from old.matching_paused then
    insert into public.auto_accept_admin_settings_history (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'matching_paused', old.matching_paused::text, new.matching_paused::text);
  end if;
  if new.premium_per_hour is distinct from old.premium_per_hour then
    insert into public.auto_accept_admin_settings_history (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'premium_per_hour', old.premium_per_hour::text, new.premium_per_hour::text);
  end if;
  if new.max_auto_bookings_per_locum_per_hour is distinct from old.max_auto_bookings_per_locum_per_hour then
    insert into public.auto_accept_admin_settings_history (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'max_auto_bookings_per_locum_per_hour',
            old.max_auto_bookings_per_locum_per_hour::text,
            new.max_auto_bookings_per_locum_per_hour::text);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_admin_historique on public.auto_accept_admin_settings;
create trigger trg_aa_admin_historique
  after update on public.auto_accept_admin_settings
  for each row execute function public.aa_journaliser_reglages_admin();

-- Écriture UNIQUEMENT par cette fonction (admin) — garde-fou : une prime
-- > 15 $/h exige le drapeau de confirmation explicite.
create or replace function public.modifier_reglages_auto_acceptation(
  p_feature_enabled boolean default null,
  p_matching_paused boolean default null,
  p_premium_per_hour numeric default null,
  p_max_par_heure int default null,
  p_confirmer_premium_eleve boolean default false
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.est_admin() then
    raise exception 'Accès refusé';
  end if;
  if p_premium_per_hour is not null and p_premium_per_hour > 15
     and not coalesce(p_confirmer_premium_eleve, false) then
    raise exception 'Prime > 15 $/h : confirmation explicite requise (p_confirmer_premium_eleve = true)';
  end if;

  update public.auto_accept_admin_settings
     set feature_enabled  = coalesce(p_feature_enabled,  feature_enabled),
         matching_paused  = coalesce(p_matching_paused,  matching_paused),
         premium_per_hour = coalesce(p_premium_per_hour, premium_per_hour),
         max_auto_bookings_per_locum_per_hour
                          = coalesce(p_max_par_heure, max_auto_bookings_per_locum_per_hour)
   where id = 1;
end;
$$;
revoke all on function public.modifier_reglages_auto_acceptation(boolean, boolean, numeric, int, boolean) from public, anon;
grant execute on function public.modifier_reglages_auto_acceptation(boolean, boolean, numeric, int, boolean) to authenticated;

alter table public.auto_accept_admin_settings enable row level security;
drop policy if exists aa_admin_settings_select on public.auto_accept_admin_settings;
create policy aa_admin_settings_select on public.auto_accept_admin_settings
  for select using (public.est_admin());
-- Volontairement AUCUNE politique insert/update/delete : toute écriture
-- passe par modifier_reglages_auto_acceptation() (security definer).

alter table public.auto_accept_admin_settings_history enable row level security;
drop policy if exists aa_admin_history_select on public.auto_accept_admin_settings_history;
create policy aa_admin_history_select on public.auto_accept_admin_settings_history
  for select using (public.est_admin());

-- ---------------------------------------------------------------------
-- 2) RÉGLAGES DU PHARMACIEN
--    enabled_since : posé à l'activation, effacé à la désactivation —
--    départage les ex æquo (récompense l'auto-acceptation gardée active).
--    excluded_weekdays : jours de semaine exclus, convention Postgres
--    extract(dow) → 0 = dimanche … 6 = samedi.
--    suspended_until : posé par le contrôle d'abus (2 annulations / 90 j) ;
--    réactivation impossible avant cette date.
-- ---------------------------------------------------------------------
create table if not exists public.auto_accept_locum_settings (
  pharmacien_id uuid primary key references public.profiles(id) on delete cascade,
  enabled boolean not null default false,
  enabled_since timestamptz,
  max_distance_km int check (max_distance_km is null or max_distance_km > 0),
  max_hours_per_shift numeric check (max_hours_per_shift is null or max_hours_per_shift > 0),
  min_rate numeric check (min_rate is null or min_rate > 0),
  excluded_weekdays int[] default null,
  excluded_date_ranges daterange[] default null,
  suspended_until timestamptz,
  updated_at timestamptz not null default now()
);

create or replace function public.aa_gerer_enabled_since()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.enabled then
      if new.suspended_until is not null and new.suspended_until > now() then
        raise exception 'Auto-acceptation suspendue jusqu''au % — réactivation impossible avant',
          to_char(new.suspended_until at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI');
      end if;
      new.enabled_since := now();
    else
      new.enabled_since := null;
    end if;
    return new;
  end if;

  -- UPDATE : enabled_since n'est JAMAIS fourni par le client — il est
  -- entièrement géré ici (sinon un pharmacien pourrait se forger une
  -- ancienneté et voler la priorité de départage).
  new.enabled_since := old.enabled_since;
  new.suspended_until := old.suspended_until;   -- non modifiable par le client

  if new.enabled and not old.enabled then
    if old.suspended_until is not null and old.suspended_until > now() then
      raise exception 'Auto-acceptation suspendue jusqu''au % — réactivation impossible avant',
        to_char(old.suspended_until at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI');
    end if;
    new.enabled_since := now();
  elsif not new.enabled and old.enabled then
    new.enabled_since := null;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_aa_locum_enabled_since on public.auto_accept_locum_settings;
create trigger trg_aa_locum_enabled_since
  before insert or update on public.auto_accept_locum_settings
  for each row execute function public.aa_gerer_enabled_since();

alter table public.auto_accept_locum_settings enable row level security;
drop policy if exists aa_locum_settings_soi on public.auto_accept_locum_settings;
-- PAS de politique DELETE : sinon un pharmacien suspendu pourrait effacer
-- sa ligne et la recréer pour blanchir sa suspension.
drop policy if exists aa_locum_settings_select on public.auto_accept_locum_settings;
create policy aa_locum_settings_select on public.auto_accept_locum_settings
  for select using (pharmacien_id = auth.uid() or public.est_admin());
drop policy if exists aa_locum_settings_insert on public.auto_accept_locum_settings;
create policy aa_locum_settings_insert on public.auto_accept_locum_settings
  for insert with check (pharmacien_id = auth.uid());
drop policy if exists aa_locum_settings_update on public.auto_accept_locum_settings;
create policy aa_locum_settings_update on public.auto_accept_locum_settings
  for update using (pharmacien_id = auth.uid() or public.est_admin())
  with check (pharmacien_id = auth.uid() or public.est_admin());

-- Suspension/réactivation par le SYSTÈME (contrôle d'abus, moteur) :
-- fonction dédiée, hors RLS.
create or replace function public.aa_suspendre_locum(p_pharmacien uuid, p_jusqua timestamptz)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.auto_accept_locum_settings
     set enabled = false,
         enabled_since = null,          -- perd la priorité d'ancienneté
         suspended_until = p_jusqua,
         updated_at = now()
   where pharmacien_id = p_pharmacien;
end;
$$;
revoke all on function public.aa_suspendre_locum(uuid, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) CONFIRMATIONS MENSUELLES DE CALENDRIER
--    Une ligne par pharmacien par mois (1er du mois) ; re-confirmer met
--    à jour confirmed_at. Une MODIFICATION du calendrier (disponibilites)
--    confirme automatiquement le mois touché — l'édition prouve que le
--    calendrier est à jour.
-- ---------------------------------------------------------------------
create table if not exists public.locum_calendar_confirmations (
  locum_id uuid not null references public.profiles(id) on delete cascade,
  month date not null check (month = date_trunc('month', month)::date),
  confirmed_at timestamptz not null default now(),
  primary key (locum_id, month)
);

alter table public.locum_calendar_confirmations enable row level security;
drop policy if exists aa_calendrier_confirm_soi on public.locum_calendar_confirmations;
create policy aa_calendrier_confirm_soi on public.locum_calendar_confirmations
  for select using (locum_id = auth.uid() or public.est_admin());
-- Écriture via la RPC ci-dessous (normalise la date au 1er du mois).

create or replace function public.confirmer_mon_calendrier(p_mois date)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  insert into public.locum_calendar_confirmations (locum_id, month, confirmed_at)
  values (auth.uid(), date_trunc('month', p_mois)::date, now())
  on conflict (locum_id, month) do update set confirmed_at = now();
end;
$$;
revoke all on function public.confirmer_mon_calendrier(date) from public, anon;
grant execute on function public.confirmer_mon_calendrier(date) to authenticated;

-- Auto-confirmation à l'édition du calendrier : trigger sur la TABLE
-- disponibilites (la page disponibilites.html n'est pas touchée).
create or replace function public.aa_confirmer_mois_sur_edition()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_qui uuid; v_date date;
begin
  if tg_op = 'DELETE' then
    v_qui := old.pharmacien_id; v_date := old.date_dispo;
  else
    v_qui := new.pharmacien_id; v_date := new.date_dispo;
  end if;
  insert into public.locum_calendar_confirmations (locum_id, month, confirmed_at)
  values (v_qui, date_trunc('month', v_date)::date, now())
  on conflict (locum_id, month) do update set confirmed_at = now();
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_aa_confirmer_mois on public.disponibilites;
create trigger trg_aa_confirmer_mois
  after insert or update or delete on public.disponibilites
  for each row execute function public.aa_confirmer_mois_sur_edition();

-- ---------------------------------------------------------------------
-- 4) COLONNES CONTRATS — traçabilité de l'auto-acceptation
--    premium_applied_per_hour : PHOTOGRAPHIE de la prime admin au moment
--    de la réservation (la valeur vivante peut changer ensuite).
-- ---------------------------------------------------------------------
alter table public.contrats
  add column if not exists filled_via_auto_accept boolean not null default false;
alter table public.contrats
  add column if not exists premium_applied_per_hour numeric;

-- ---------------------------------------------------------------------
-- 5) CANDIDATURES — type 'auto_acceptation' + période réelle du quart
--    (colonne tstzrange entretenue par trigger, fuseau America/Toronto,
--    quart de nuit = fin le lendemain).
-- ---------------------------------------------------------------------
alter table public.candidatures
  drop constraint if exists candidatures_type_candidature_check;
alter table public.candidatures
  add constraint candidatures_type_candidature_check
  check (type_candidature in ('instantanee','negociee','auto_acceptation'));

alter table public.candidatures
  add column if not exists periode tstzrange;

create or replace function public.aa_calculer_periode()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare k public.contrats%rowtype; v_hd time; v_hf time;
begin
  select * into k from public.contrats where id = new.contrat_id;
  if not found then return new; end if;
  -- un contrat ANNULÉ ne bloque plus l'horaire : periode reste vide
  if k.statut = 'annule' then
    new.periode := null;
    return new;
  end if;
  v_hd := coalesce(new.heure_debut_proposee, k.heure_debut);
  v_hf := coalesce(new.heure_fin_proposee,  k.heure_fin);
  new.periode := tstzrange(
    (k.date_contrat::timestamp + v_hd) at time zone 'America/Toronto',
    ((k.date_contrat + case when v_hf <= v_hd then 1 else 0 end)::timestamp + v_hf)
      at time zone 'America/Toronto',
    '[)');
  return new;
end;
$$;

drop trigger if exists trg_aa_periode on public.candidatures;
create trigger trg_aa_periode
  before insert or update of heure_debut_proposee, heure_fin_proposee, statut
  on public.candidatures
  for each row execute function public.aa_calculer_periode();

-- Remplissage des candidatures ACCEPTÉES existantes (une passe).
update public.candidatures c
   set periode = tstzrange(
     (k.date_contrat::timestamp + coalesce(c.heure_debut_proposee, k.heure_debut))
       at time zone 'America/Toronto',
     ((k.date_contrat + case when coalesce(c.heure_fin_proposee, k.heure_fin)
                              <= coalesce(c.heure_debut_proposee, k.heure_debut)
                        then 1 else 0 end)::timestamp
       + coalesce(c.heure_fin_proposee, k.heure_fin))
       at time zone 'America/Toronto',
     '[)')
  from public.contrats k
 where k.id = c.contrat_id and c.statut = 'accepte' and c.periode is null
   and k.statut <> 'annule';

-- Une candidature acceptée d'un contrat ANNULÉ garde son statut (historique,
-- sql/09 : l'annulation pharmacie ne touche pas la candidature) mais ne doit
-- plus bloquer l'horaire ni la contrainte : periode effacée, et un trigger
-- l'efface à chaque annulation future.
update public.candidatures c
   set periode = null
  from public.contrats k
 where k.id = c.contrat_id and k.statut = 'annule' and c.periode is not null;

create or replace function public.aa_liberer_periode_sur_annulation()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.statut = 'annule' and old.statut <> 'annule' then
    update public.candidatures set periode = null
     where contrat_id = new.id and statut = 'accepte';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_aa_liberer_periode on public.contrats;
create trigger trg_aa_liberer_periode
  after update of statut on public.contrats
  for each row execute function public.aa_liberer_periode_sur_annulation();

-- Vérification AVANT de poser la contrainte : s'il existe déjà des
-- chevauchements acceptés, on échoue avec un message clair (au lieu de
-- l'erreur brute de la contrainte).
do $$
declare v_liste text;
begin
  select string_agg(distinct k1.numero_reference || ' / ' || k2.numero_reference, ', ')
    into v_liste
    from public.candidatures c1
    join public.candidatures c2
      on c2.pharmacien_id = c1.pharmacien_id and c2.id > c1.id
     and c2.statut = 'accepte' and c1.statut = 'accepte'
     and c1.periode && c2.periode
    join public.contrats k1 on k1.id = c1.contrat_id and k1.statut <> 'annule'
    join public.contrats k2 on k2.id = c2.contrat_id and k2.statut <> 'annule';
  if v_liste is not null then
    raise exception 'Chevauchements existants entre contrats acceptés : %. À résoudre avant de poser la contrainte anti-double-réservation.', v_liste;
  end if;
end $$;

-- LA GARANTIE : la base refuse tout chevauchement de contrats acceptés
-- pour un même pharmacien — quel que soit le chemin de code.
alter table public.candidatures
  drop constraint if exists candidatures_pas_de_chevauchement;
alter table public.candidatures
  add constraint candidatures_pas_de_chevauchement
  exclude using gist (pharmacien_id with =, periode with &&)
  where (statut = 'accepte' and periode is not null);

-- ---------------------------------------------------------------------
-- 6) CONTRÔLE D'ABUS — annulations de quarts auto-acceptés
--    2e annulation en 90 jours → auto-acceptation coupée 30 jours,
--    enabled_since effacé (retour en fin de file de priorité), notifié.
--    (Le trigger qui alimente cette table arrive au SQL 69 — il a besoin
--    de la file de notifications déclarée ci-dessous.)
-- ---------------------------------------------------------------------
create table if not exists public.annulations_auto_acceptation (
  id uuid primary key default gen_random_uuid(),
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  candidature_id uuid references public.candidatures(id) on delete set null,
  contrat_id uuid references public.contrats(id) on delete set null,
  annule_le timestamptz not null default now()
);
create index if not exists idx_aa_annulations_pharmacien
  on public.annulations_auto_acceptation (pharmacien_id, annule_le);

alter table public.annulations_auto_acceptation enable row level security;
drop policy if exists aa_annulations_admin on public.annulations_auto_acceptation;
create policy aa_annulations_admin on public.annulations_auto_acceptation
  for select using (public.est_admin());

-- ---------------------------------------------------------------------
-- 7) FILE DE NOTIFICATIONS (push + courriel) — remplie par le moteur SQL,
--    vidée par le Worker c-direct-sms (cron 1 min). Les SMS, eux, passent
--    par la sms_queue existante.
-- ---------------------------------------------------------------------
create table if not exists public.file_notifications (
  id uuid primary key default gen_random_uuid(),
  profil_id uuid references public.profiles(id) on delete cascade,
  canal text not null check (canal in ('push','courriel')),
  payload jsonb not null,
  statut text not null default 'attente' check (statut in ('attente','envoi','envoye','echec')),
  created_at timestamptz not null default now(),
  traite_le timestamptz
);
create index if not exists idx_file_notifications_statut
  on public.file_notifications (statut, created_at);

alter table public.file_notifications enable row level security;
-- Volontairement AUCUNE politique : lecture/écriture réservées au moteur
-- (security definer) et au Worker (service_role).

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   select * from public.auto_accept_admin_settings;          -- 1 ligne, feature OFF
--   \d public.candidatures                                     -- contrainte candidatures_pas_de_chevauchement
--   select count(*) from public.locum_calendar_confirmations;  -- 0 (ou +, si éditions déjà faites)
-- =====================================================================
