-- =====================================================================
-- C-DIRECT · SQL 69 — AUTO-ACCEPTATION (JOB 1/2) · FILE D'ÉVÈNEMENTS + JOURNAL
-- À exécuter APRÈS 68-auto-acceptation-fondations.sql.
--
-- Architecture SÉQUENCEUR UNIQUE (pas de matching par triggers parallèles) :
-- les évènements ne font qu'INSÉRER une ligne dans matching_queue ; UN SEUL
-- moteur planifié (SQL 70 + 71) traite la file en ordre d'id, strictement
-- en série — les courses de réservation sont impossibles PAR CONSTRUCTION.
--
--   · matching_queue : file d'évènements (id bigserial = ordre de traitement)
--   · match_log : journal APPEND-ONLY — chaque pharmacien évalué contre
--     chaque quart, échecs inclus (porte qui a échoué + détail jsonb)
--   · triggers producteurs d'évènements :
--       contrat publié / republié            → shift_posted
--       contrat annulé                       → shift_cancelled (+ schedule_freed)
--       réglages pharmacien activés/modifiés → locum_settings_changed
--       calendrier modifié                   → schedule_freed
--       désistement d'un contrat accepté     → schedule_freed
--   · contrôle d'abus : 2e annulation d'un quart auto-accepté en 90 jours
--     → suspension 30 jours + notification
--
-- Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) FILE D'ÉVÈNEMENTS
-- ---------------------------------------------------------------------
create table if not exists public.matching_queue (
  id bigserial primary key,                    -- ordre de traitement
  event_type text not null check (event_type in
    ('shift_posted','locum_settings_changed','schedule_freed','shift_cancelled')),
  payload jsonb not null default '{}',
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  status text not null default 'pending' check (status in ('pending','processed','failed')),
  erreur text                                   -- rempli si status = 'failed'
);
create index if not exists idx_matching_queue_pending
  on public.matching_queue (status, id) where status = 'pending';

alter table public.matching_queue enable row level security;
-- Volontairement AUCUNE politique : la file n'est PAS accessible aux clients.

create or replace function public.aa_enqueue(p_type text, p_payload jsonb)
returns void
language sql security definer set search_path = public
as $$
  insert into public.matching_queue (event_type, payload) values (p_type, p_payload);
$$;
revoke all on function public.aa_enqueue(text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) JOURNAL DE MATCHING — APPEND-ONLY, LES ÉCHECS AUSSI
--    result : matched | booked | rejected
--    rejection_gate : lettre de la porte qui a échoué (a…k, 'd-bis',
--    'd-constraint' si la contrainte d'exclusion s'est déclenchée — signal
--    de bogue, pas du bruit). Jamais modifié, jamais supprimé.
-- ---------------------------------------------------------------------
create table if not exists public.match_log (
  id bigserial primary key,
  shift_id uuid not null references public.contrats(id) on delete cascade,
  locum_id uuid not null references public.profiles(id) on delete cascade,
  evaluated_at timestamptz not null default now(),
  result text not null check (result in ('matched','booked','rejected')),
  rejection_gate text,
  detail jsonb
);
create index if not exists idx_match_log_locum on public.match_log (locum_id, evaluated_at);
create index if not exists idx_match_log_shift on public.match_log (shift_id);
-- Plafond horaire : compte des 'booked' de la dernière heure par pharmacien.
create index if not exists idx_match_log_booked
  on public.match_log (locum_id, evaluated_at) where result = 'booked';

alter table public.match_log enable row level security;
drop policy if exists match_log_admin on public.match_log;
create policy match_log_admin on public.match_log
  for select using (public.est_admin());
-- Les pharmaciens passent par la vue API (SQL 72), jamais par la table.

-- Append-only au niveau base : refus de UPDATE/DELETE même pour un rôle
-- qui contournerait la RLS.
create or replace function public.aa_interdire_modification()
returns trigger
language plpgsql
as $$
begin
  raise exception 'match_log est un journal en ajout seul (append-only)';
end;
$$;
drop trigger if exists trg_match_log_fige on public.match_log;
create trigger trg_match_log_fige
  before update or delete on public.match_log
  for each row execute function public.aa_interdire_modification();

-- ---------------------------------------------------------------------
-- 3) PRODUCTEURS D'ÉVÈNEMENTS
-- ---------------------------------------------------------------------

-- 3a) contrats : publication, republication, annulation.
create or replace function public.aa_evenement_contrat()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_pharmacien uuid;
begin
  if tg_op = 'INSERT' then
    if new.statut = 'ouvert' then
      perform public.aa_enqueue('shift_posted', jsonb_build_object('contrat_id', new.id));
    end if;
    return new;
  end if;

  -- Republication (désistement du pharmacien : attribue → ouvert)
  if new.statut = 'ouvert' and old.statut = 'attribue' then
    perform public.aa_enqueue('shift_posted', jsonb_build_object('contrat_id', new.id));
    -- le contrat redevient réservable par auto-acceptation
    new.filled_via_auto_accept := false;
    new.premium_applied_per_hour := null;
  end if;

  -- Annulation
  if new.statut = 'annule' and old.statut <> 'annule' then
    perform public.aa_enqueue('shift_cancelled', jsonb_build_object('contrat_id', new.id));
    if old.statut = 'attribue' then
      select c.pharmacien_id into v_pharmacien
        from public.candidatures c
       where c.contrat_id = new.id and c.statut = 'accepte'
       order by c.updated_at desc limit 1;
      if v_pharmacien is not null then
        perform public.aa_enqueue('schedule_freed', jsonb_build_object('pharmacien_id', v_pharmacien));
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_evenement_contrat on public.contrats;
create trigger trg_aa_evenement_contrat
  before insert or update of statut on public.contrats
  for each row execute function public.aa_evenement_contrat();

-- 3b) réglages pharmacien : activation ou modification pendant que c'est actif.
-- [T27 batch1 — no-op délibéré, documenté] : quand un pharmacien RESSERRE
-- ses filtres (ex. distance max réduite) alors qu'il est déjà activé, la
-- réévaluation complète relancée ici ne peut produire aucun nouveau match
-- (resserrer ne fait qu'exclure). C'est une petite dépense de calcul
-- assumée : distinguer « resserré » de « élargi » champ par champ coûterait
-- plus en complexité (et en risques de faux négatifs) que les quelques
-- évaluations superflues toutes gérées par les portes du moteur (sql/70).
create or replace function public.aa_evenement_reglages()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.enabled then
    perform public.aa_enqueue('locum_settings_changed',
      jsonb_build_object('pharmacien_id', new.pharmacien_id));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_evenement_reglages on public.auto_accept_locum_settings;
create trigger trg_aa_evenement_reglages
  after insert or update on public.auto_accept_locum_settings
  for each row execute function public.aa_evenement_reglages();

-- 3c) calendrier (disponibilites) : toute édition peut libérer une journée.
--     N'enfile que si le pharmacien a l'auto-acceptation active (évite le
--     bruit pour tous les autres).
create or replace function public.aa_evenement_calendrier()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_qui uuid;
begin
  v_qui := coalesce(new.pharmacien_id, old.pharmacien_id);
  if exists (select 1 from public.auto_accept_locum_settings s
              where s.pharmacien_id = v_qui and s.enabled) then
    perform public.aa_enqueue('schedule_freed', jsonb_build_object('pharmacien_id', v_qui));
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_aa_evenement_calendrier on public.disponibilites;
create trigger trg_aa_evenement_calendrier
  after insert or update or delete on public.disponibilites
  for each row execute function public.aa_evenement_calendrier();

-- 3d) désistement d'un contrat accepté (accepte → refuse) : horaire libéré.
--     Si le contrat était AUTO-ACCEPTÉ : suivi d'abus (2 en 90 j → 30 j
--     de suspension, enabled_since effacé, pharmacien notifié pourquoi).
create or replace function public.aa_evenement_desistement()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare v_nb int; v_tel text; v_optin boolean;
begin
  if old.statut = 'accepte' and new.statut = 'refuse' then
    perform public.aa_enqueue('schedule_freed',
      jsonb_build_object('pharmacien_id', new.pharmacien_id));

    if old.type_candidature = 'auto_acceptation' then
      insert into public.annulations_auto_acceptation (pharmacien_id, candidature_id, contrat_id)
      values (new.pharmacien_id, new.id, new.contrat_id);

      select count(*) into v_nb
        from public.annulations_auto_acceptation
       where pharmacien_id = new.pharmacien_id
         and annule_le > now() - interval '90 days';

      if v_nb >= 2 then
        perform public.aa_suspendre_locum(new.pharmacien_id, now() + interval '30 days');

        insert into public.file_notifications (profil_id, canal, payload)
        values (new.pharmacien_id, 'push', jsonb_build_object(
          'title', 'Auto-acceptation suspendue 30 jours',
          'body',  '2e annulation d''un quart auto-accepté en 90 jours. Votre ancienneté de priorité est remise à zéro.',
          'url',   '/parametres.html'));

        select telephone, sms_optin into v_tel, v_optin
          from public.profiles where id = new.pharmacien_id;
        if v_tel is not null and coalesce(v_optin, false) then
          insert into public.sms_queue (profile_id, contrat_id, to_number, type, corps)
          values (new.pharmacien_id, new.contrat_id, v_tel, 'auto_accept_suspension',
            'C-Direct: Auto-acceptation suspendue 30 jours (2e annulation d''un quart auto-accepte en 90 jours). Votre priorite d''anciennete est remise a zero.');
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_evenement_desistement on public.candidatures;
create trigger trg_aa_evenement_desistement
  after update of statut on public.candidatures
  for each row execute function public.aa_evenement_desistement();

-- 3e) interrupteur maître : quand feature_enabled passe à ON, tous les
--     contrats ouverts à venir entrent dans la file (sinon les quarts
--     publiés pendant que la fonction était éteinte ne seraient jamais
--     évalués). La reprise après matching_paused n'a besoin de rien : la
--     file s'est accumulée toute seule.
create or replace function public.aa_evenement_admin()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.feature_enabled and not old.feature_enabled then
    insert into public.matching_queue (event_type, payload)
    select 'shift_posted', jsonb_build_object('contrat_id', k.id)
      from public.contrats k
     where k.statut = 'ouvert' and k.date_contrat >= current_date;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_aa_evenement_admin on public.auto_accept_admin_settings;
create trigger trg_aa_evenement_admin
  after update on public.auto_accept_admin_settings
  for each row execute function public.aa_evenement_admin();

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   insert d'un contrat de test → select * from matching_queue;  (1 ligne shift_posted)
--   update/delete sur match_log → doit échouer (append-only)
-- =====================================================================
