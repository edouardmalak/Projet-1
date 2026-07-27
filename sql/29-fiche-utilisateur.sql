-- =====================================================================
-- C-DIRECT · SQL 29 — FICHE UTILISATEUR (Zone Admin F, nice-to-have)
-- À exécuter dans Supabase → SQL Editor, APRÈS 28-dashboard-regions.sql.
-- Idempotent (create or replace / if not exists).
--
-- Vue détaillée d'un seul compte : profil + vérification + fiabilité +
-- historique des contrats + historique des factures + notes internes +
-- journal SMS (comms log — lu directement depuis sms_log, déjà RLS
-- admin-only, pas besoin de RPC). Suspendre/réactiver réutilise
-- admin_maj_verification (SQL 25) — pas de nouvelle RPC d'écriture pour
-- le statut, seulement pour les notes (append-only, comme SQL 26).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Notes internes admin PAR UTILISATEUR (distinct de contrat_notes_admin,
-- SQL 26, qui est par contrat). Même pattern append-only.
-- ---------------------------------------------------------------------
create table if not exists public.profil_notes_admin (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  admin_id uuid references public.profiles(id) on delete set null,
  note text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_profil_notes_profile on public.profil_notes_admin (profile_id, created_at desc);

alter table public.profil_notes_admin enable row level security;
drop policy if exists "profil_notes_admin_all" on public.profil_notes_admin;
create policy "profil_notes_admin_all" on public.profil_notes_admin
  for all using (public.est_admin()) with check (public.est_admin());

-- ---------------------------------------------------------------------
-- get_profil_detail — l'en-tête de la fiche : identité, vérification,
-- fiabilité (mandats complétés/annulés pour un pharmacien ; contrats
-- publiés/pourvus/annulés pour une pharmacie).
-- ---------------------------------------------------------------------
create or replace function public.get_profil_detail(p_profil uuid)
returns table (
  id uuid, role text, statut_verification text, approuve boolean,
  verification_raison text, verification_maj_le timestamptz, verification_par_nom text,
  nom text, prenom text, courriel text, telephone text, sms_optin boolean, cree_le timestamptz,
  numero_opq text, ville_base text, code_postal text,
  nom_pharmacie text, neq text, banniere text, adresse text, ville text,
  contact_proprietaire text, cell_proprietaire text,
  mandats_completes bigint, mandats_annules bigint, mandats_total bigint, taux_completion int,
  contrats_publies bigint, contrats_pourvus bigint, contrats_annules bigint
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select p.id, p.role, p.statut_verification, p.approuve,
           p.verification_raison, p.verification_maj_le,
           nullif(trim(coalesce(v.prenom,'') || ' ' || coalesce(v.nom,'')), ''),
           p.nom, p.prenom, p.courriel, p.telephone, p.sms_optin, p.created_at,
           p.numero_opq, p.ville_base, p.code_postal,
           p.nom_pharmacie, p.neq, p.banniere, p.adresse, p.ville,
           p.contact_proprietaire, p.cell_proprietaire,
           case when p.role = 'pharmacien' then s.completes else null end,
           case when p.role = 'pharmacien' then s.annulations else null end,
           case when p.role = 'pharmacien' then s.total else null end,
           case when p.role = 'pharmacien' then s.taux_completion else null end,
           case when p.role = 'pharmacie' then
             (select count(*) from public.contrats k where k.pharmacie_id = p.id) else null end,
           case when p.role = 'pharmacie' then
             (select count(*) from public.contrats k where k.pharmacie_id = p.id and k.statut in ('attribue','complete')) else null end,
           case when p.role = 'pharmacie' then
             (select count(*) from public.contrats k where k.pharmacie_id = p.id and k.statut = 'annule') else null end
      from public.profiles p
      left join public.profiles v on v.id = p.verification_par
      left join lateral public.get_stats_pharmacien(p.id) s on p.role = 'pharmacien'
     where p.id = p_profil;
end;
$$;
revoke all on function public.get_profil_detail(uuid) from public, anon;
grant execute on function public.get_profil_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- get_historique_contrats_profil — les contrats liés à ce compte
-- (posés par lui, s'il est pharmacie ; où sa candidature fut acceptée,
-- s'il est pharmacien), plus récents en premier.
-- ---------------------------------------------------------------------
create or replace function public.get_historique_contrats_profil(p_profil uuid)
returns table (
  id uuid, numero_reference text, statut text, date_contrat date,
  tarif_horaire numeric, autre_partie text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select k.id, k.numero_reference, k.statut, k.date_contrat, k.tarif_horaire,
           case when k.pharmacie_id = p_profil
                then coalesce((select nullif(trim(coalesce(pn.prenom,'')||' '||coalesce(pn.nom,'')), '')
                                 from public.candidatures c join public.profiles pn on pn.id = c.pharmacien_id
                                where c.contrat_id = k.id and c.statut = 'accepte' limit 1), '— non assigné')
                else (select pe.nom_pharmacie from public.profiles pe where pe.id = k.pharmacie_id)
           end
      from public.contrats k
     where k.pharmacie_id = p_profil
        or exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = p_profil and c.statut = 'accepte')
     order by k.created_at desc
     limit 200;
end;
$$;
revoke all on function public.get_historique_contrats_profil(uuid) from public, anon;
grant execute on function public.get_historique_contrats_profil(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- get_historique_factures_profil — les factures liées à ce compte.
-- ---------------------------------------------------------------------
create or replace function public.get_historique_factures_profil(p_profil uuid)
returns table (
  facture_id uuid, numero_facture int, type_facture text, statut text,
  total numeric, date_echeance date, cree_le timestamptz, numero_reference text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select f.id, f.numero_facture, f.type_facture, f.statut, f.total, f.date_echeance, f.created_at,
           k.numero_reference
      from public.factures f
      join public.candidatures c on c.id = f.candidature_id
      join public.contrats k on k.id = c.contrat_id
     where c.pharmacien_id = p_profil or k.pharmacie_id = p_profil
     order by f.created_at desc
     limit 200;
end;
$$;
revoke all on function public.get_historique_factures_profil(uuid) from public, anon;
grant execute on function public.get_historique_factures_profil(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- get_notes_profil / admin_ajouter_note_profil — notes internes,
-- même pattern que contrat_notes_admin (SQL 26).
-- ---------------------------------------------------------------------
create or replace function public.get_notes_profil(p_profil uuid)
returns table (id uuid, note text, cree_le timestamptz, admin_nom text)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select n.id, n.note, n.created_at,
           nullif(trim(coalesce(p.prenom,'') || ' ' || coalesce(p.nom,'')), '')
      from public.profil_notes_admin n
      left join public.profiles p on p.id = n.admin_id
     where n.profile_id = p_profil
     order by n.created_at desc;
end;
$$;
revoke all on function public.get_notes_profil(uuid) from public, anon;
grant execute on function public.get_notes_profil(uuid) to authenticated;

create or replace function public.admin_ajouter_note_profil(p_profil uuid, p_note text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_nom text;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_note is null or length(trim(p_note)) < 2 then raise exception 'Note vide'; end if;

  select coalesce(nom_pharmacie, nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), courriel)
    into v_nom from public.profiles where id = p_profil;
  if v_nom is null then raise exception 'Profil introuvable'; end if;

  insert into public.profil_notes_admin (profile_id, admin_id, note)
  values (p_profil, auth.uid(), trim(p_note));

  perform public.admin_logger(
    'profil_note', 'profile', p_profil::text,
    jsonb_build_object('nom', v_nom, 'note', left(trim(p_note), 200))
  );
end;
$$;
revoke all on function public.admin_ajouter_note_profil(uuid, text) from public, anon;
grant execute on function public.admin_ajouter_note_profil(uuid, text) to authenticated;
