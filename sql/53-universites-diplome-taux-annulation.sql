-- =====================================================================
-- C-DIRECT · SQL 53 — PROFIL PHARMACIEN : UNIVERSITÉS, DIPLÔME,
-- TAUX D'ANNULATION, RETARD SIGNALÉ
-- Ajoute universités fréquentées (max 3, liste fixe côté client),
-- année/mois de graduation (expérience calculée côté client), le
-- taux d'annulation À L'INITIATIVE DU PHARMACIEN, et un nouveau
-- mécanisme « signaler un retard » (nouvelle heure de début annoncée
-- après le début réel du quart, sur un contrat déjà confirmé) avec
-- son propre taux. Distinct des colonnes existantes de sql/20, qui
-- mesurent l'impact des annulations DE LA PHARMACIE sur ce pharmacien.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Universités + diplôme
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists universites text[];
alter table public.profiles add column if not exists diplome_annee int;
alter table public.profiles add column if not exists diplome_mois int;

do $$ begin
  alter table public.profiles add constraint profiles_universites_max3
    check (universites is null or array_length(universites,1) <= 3);
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.profiles add constraint profiles_diplome_mois_valide
    check (diplome_mois is null or diplome_mois between 1 and 12);
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.profiles add constraint profiles_diplome_annee_valide
    check (diplome_annee is null or diplome_annee between 1950 and extract(year from now())::int + 1);
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------
-- 2) « Signaler un retard » — table + RPC
-- Un pharmacien confirmé sur un contrat (candidatures.statut='accepte')
-- peut annoncer, le jour même et seulement une fois le quart commencé
-- (heure_debut dépassée), une nouvelle heure de début plus tardive.
-- Log-only : aucune approbation requise, la pharmacie est simplement
-- avertie par courriel (même mécanisme que sql/06). Une seule
-- déclaration par contrat (unique index).
-- ---------------------------------------------------------------------
create table if not exists public.demandes_retard (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  heure_debut_prevue time not null,
  heure_debut_annoncee time not null,
  motif text,
  cree_le timestamptz not null default now()
);
create unique index if not exists demandes_retard_un_par_contrat
  on public.demandes_retard(contrat_id, pharmacien_id);

alter table public.demandes_retard enable row level security;

drop policy if exists "pharmacien lit ses propres retards" on public.demandes_retard;
create policy "pharmacien lit ses propres retards" on public.demandes_retard
  for select using (auth.uid() = pharmacien_id);

drop policy if exists "pharmacie lit les retards de ses contrats" on public.demandes_retard;
create policy "pharmacie lit les retards de ses contrats" on public.demandes_retard
  for select using (
    auth.uid() = (select c.pharmacie_id from public.contrats c where c.id = contrat_id)
  );

-- Pas de policy insert/update/delete cliente : uniquement via
-- declarer_retard (security definer) ci-dessous, qui valide tout.

create or replace function public.declarer_retard(
  p_contrat uuid, p_nouvelle_heure_debut time, p_motif text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_contrat public.contrats%rowtype;
  v_candidature public.candidatures%rowtype;
  v_aujourdhui_qc date := (now() at time zone 'America/Toronto')::date;
  v_debut_prevu timestamptz;
  v_id uuid;
begin
  select * into v_contrat from public.contrats where id = p_contrat;
  if v_contrat is null then
    raise exception 'Contrat introuvable.';
  end if;

  select * into v_candidature from public.candidatures
    where contrat_id = p_contrat and pharmacien_id = auth.uid() and statut = 'accepte';
  if v_candidature is null then
    raise exception 'Vous n''êtes pas le pharmacien confirmé pour ce contrat.';
  end if;

  if v_contrat.date_contrat <> v_aujourdhui_qc then
    raise exception 'Cette déclaration n''est possible que le jour même du contrat.';
  end if;

  v_debut_prevu := ((v_contrat.date_contrat::text || ' ' || v_contrat.heure_debut::text)::timestamp
                     at time zone 'America/Toronto');
  if now() <= v_debut_prevu then
    raise exception 'Le quart n''a pas encore commencé.';
  end if;

  if p_nouvelle_heure_debut <= v_contrat.heure_debut then
    raise exception 'La nouvelle heure doit être plus tard que l''heure prévue.';
  end if;

  insert into public.demandes_retard
    (contrat_id, pharmacien_id, heure_debut_prevue, heure_debut_annoncee, motif)
  values (p_contrat, auth.uid(), v_contrat.heure_debut, p_nouvelle_heure_debut, p_motif)
  on conflict (contrat_id, pharmacien_id) do nothing
  returning id into v_id;

  if v_id is not null then
    perform public.envoyer_email(
      (select courriel from public.profiles where id = v_contrat.pharmacie_id),
      'Retard signalé — ' || v_contrat.numero_reference,
      '<p>Bonjour,</p>' ||
      '<p>' || coalesce((select prenom || ' ' || nom from public.profiles where id = auth.uid()), 'Le pharmacien') ||
      ' a signalé un retard sur le contrat <b>' || v_contrat.numero_reference || '</b> : nouvelle heure de ' ||
      'début estimée ' || to_char(p_nouvelle_heure_debut, 'HH24:MI') || ' (prévue à ' ||
      to_char(v_contrat.heure_debut, 'HH24:MI') || ').</p>' ||
      (case when p_motif is not null and p_motif <> '' then '<p>Motif : ' || p_motif || '</p>' else '' end) ||
      '<p>— C-Direct</p>'
    );
  end if;
end;
$$;
grant execute on function public.declarer_retard(uuid, time, text) to authenticated;

-- ---------------------------------------------------------------------
-- 3) get_stats_pharmacien — même fonction (sql/20), colonnes de plus.
-- Annulation « à l'initiative du pharmacien » = jalon {'etape':'annule',
-- 'par':'pharmacien'} journalisé par annuler_contrat_pharmacien (sql/09),
-- qui fait toujours passer la candidature de 'accepte' à 'refuse' — donc
-- la seule PRÉSENCE du jalon prouve qu'elle a été confirmée un jour,
-- peu importe son statut actuel. « confirmees » = candidatures ayant un
-- jour été confirmées (statut='accepte' aujourd'hui OU annulée par moi
-- depuis) ; sert de dénominateur commun aux deux nouveaux taux.
-- RETURNS TABLE change de forme → drop requis avant recreate (Postgres
-- refuse un CREATE OR REPLACE qui change le type de retour).
-- ---------------------------------------------------------------------
drop function if exists public.get_stats_pharmacien(uuid);
create or replace function public.get_stats_pharmacien(p_profil uuid)
returns table (
  completes bigint, annulations bigint, total bigint, taux_completion int,
  confirmees_pharmacien bigint,
  annulations_pharmacien bigint, taux_annulation_pharmacien int,
  retards_pharmacien bigint, taux_retard_pharmacien int
)
language sql stable security definer set search_path = public as $$
  with mine as (
    select k.statut
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
    where c.pharmacien_id = p_profil and c.statut = 'accepte'
  ),
  miennes as (
    select c.id, c.contrat_id, c.statut,
      exists(
        select 1 from jsonb_array_elements(
          case when c.message ~ '^\s*\[' then c.message::jsonb else '[]'::jsonb end
        ) j
        where j->>'etape' = 'annule' and j->>'par' = 'pharmacien'
      ) as annulee_par_moi
    from public.candidatures c
    where c.pharmacien_id = p_profil
  ),
  confirmees as (
    select m.*,
      exists(
        select 1 from public.demandes_retard d
        where d.contrat_id = m.contrat_id and d.pharmacien_id = p_profil
      ) as en_retard
    from miennes m where m.statut = 'accepte' or m.annulee_par_moi
  )
  select
    (select count(*) filter (where statut = 'complete') from mine),
    (select count(*) filter (where statut = 'annule') from mine),
    (select count(*) from mine),
    (select coalesce(round(100.0 * count(*) filter (where statut = 'complete')
                    / nullif(count(*) filter (where statut in ('complete','annule')), 0)), 0)::int from mine),
    (select count(*) from confirmees),
    (select count(*) filter (where annulee_par_moi) from confirmees),
    (select coalesce(round(100.0 * count(*) filter (where annulee_par_moi)
                    / nullif(count(*), 0)), 0)::int from confirmees),
    (select count(*) filter (where en_retard) from confirmees),
    (select coalesce(round(100.0 * count(*) filter (where en_retard)
                    / nullif(count(*), 0)), 0)::int from confirmees);
$$;
grant execute on function public.get_stats_pharmacien(uuid) to authenticated;
