-- =====================================================================
-- C-DIRECT · SQL 26 — GESTION DES CONTRATS (Zone Admin C)
-- À exécuter dans Supabase → SQL Editor, APRÈS 25-verification-queue.sql.
-- Idempotent (create or replace / if not exists).
--
-- Objet : table maîtresse des contrats pour l'admin (pharmacie, locum,
-- tarif, région, statut) + 3 gestes admin journalisés :
--   · annuler un contrat (réutilise annuler_contrat_pharmacie — même
--     calcul de pénalité que si la pharmacie annulait elle-même)
--   · signaler / lever un litige (drapeau indépendant du statut)
--   · ajouter une note interne (visible admin seulement)
-- Le statut brut du contrat (ouvert/attribue/complete/annule) N'EST PAS
-- modifié — le litige est un drapeau superposé, pas un 5e statut, pour ne
-- rien casser des RPC existantes qui filtrent sur k.statut.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Drapeau de litige sur contrats (superposé au statut, ne le remplace pas)
-- ---------------------------------------------------------------------
alter table public.contrats
  add column if not exists en_litige boolean not null default false,
  add column if not exists litige_raison text,
  add column if not exists litige_le timestamptz,
  add column if not exists litige_par uuid references public.profiles(id);

-- ---------------------------------------------------------------------
-- Notes internes admin (append-only, jamais visibles des utilisateurs)
-- ---------------------------------------------------------------------
create table if not exists public.contrat_notes_admin (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  admin_id uuid references public.profiles(id) on delete set null,
  note text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_contrat_notes_contrat on public.contrat_notes_admin (contrat_id, created_at desc);

alter table public.contrat_notes_admin enable row level security;
drop policy if exists "contrat_notes_admin_all" on public.contrat_notes_admin;
create policy "contrat_notes_admin_all" on public.contrat_notes_admin
  for all using (public.est_admin()) with check (public.est_admin());

-- ---------------------------------------------------------------------
-- get_contrats_admin — table maîtresse : contrat + pharmacie + locum
-- (candidature acceptée, s'il y en a une) + litige + nb notes + fiabilité
-- du locum (réutilise get_stats_pharmacien, SQL 20).
-- ---------------------------------------------------------------------
create or replace function public.get_contrats_admin()
returns table (
  id uuid, numero_reference text, statut text, en_litige boolean,
  litige_raison text, litige_le timestamptz,
  date_contrat date, heure_debut time, heure_fin time, tarif_horaire numeric,
  ville text, code_postal text,
  pharmacie_id uuid, nom_pharmacie text, pharmacie_courriel text,
  pharmacie_tel text, pharmacie_contact_nom text, pharmacie_contact_tel text,
  candidature_id uuid, pharmacien_id uuid, pharmacien_nom text,
  pharmacien_courriel text, pharmacien_tel text, pharmacien_opq text,
  pharmacien_taux_completion int, pharmacien_mandats int,
  notes_count bigint, created_at timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select k.id, k.numero_reference, k.statut, k.en_litige, k.litige_raison, k.litige_le,
           k.date_contrat, k.heure_debut, k.heure_fin, k.tarif_horaire,
           pe.ville, pe.code_postal,
           pe.id, pe.nom_pharmacie, pe.courriel, pe.telephone,
           pe.contact_proprietaire, pe.cell_proprietaire,
           c.id, pn.id, nullif(trim(coalesce(pn.prenom,'') || ' ' || coalesce(pn.nom,'')), ''),
           pn.courriel, pn.telephone, pn.numero_opq,
           s.taux_completion, s.total,
           (select count(*) from public.contrat_notes_admin n where n.contrat_id = k.id),
           k.created_at
      from public.contrats k
      join public.profiles pe on pe.id = k.pharmacie_id
      left join public.candidatures c on c.contrat_id = k.id and c.statut = 'accepte'
      left join public.profiles pn on pn.id = c.pharmacien_id
      left join lateral public.get_stats_pharmacien(pn.id) s on true
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_admin() from public, anon;
grant execute on function public.get_contrats_admin() to authenticated;

-- ---------------------------------------------------------------------
-- get_notes_contrat — fil des notes internes d'un contrat, plus récentes
-- en premier, avec le prénom de l'admin auteur.
-- ---------------------------------------------------------------------
create or replace function public.get_notes_contrat(p_contrat uuid)
returns table (id uuid, note text, cree_le timestamptz, admin_nom text)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select n.id, n.note, n.created_at,
           nullif(trim(coalesce(p.prenom,'') || ' ' || coalesce(p.nom,'')), '')
      from public.contrat_notes_admin n
      left join public.profiles p on p.id = n.admin_id
     where n.contrat_id = p_contrat
     order by n.created_at desc;
end;
$$;
revoke all on function public.get_notes_contrat(uuid) from public, anon;
grant execute on function public.get_notes_contrat(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- admin_ajouter_note — ajoute une note interne + journalise (extrait
-- seulement, le fil complet vit dans contrat_notes_admin).
-- ---------------------------------------------------------------------
create or replace function public.admin_ajouter_note(p_contrat uuid, p_note text)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_ref text;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_note is null or length(trim(p_note)) < 2 then
    raise exception 'Note vide';
  end if;

  select numero_reference into v_ref from public.contrats where id = p_contrat;
  if v_ref is null then raise exception 'Contrat introuvable'; end if;

  insert into public.contrat_notes_admin (contrat_id, admin_id, note)
  values (p_contrat, auth.uid(), trim(p_note));

  perform public.admin_logger(
    'contrat_note', 'contrat', p_contrat::text,
    jsonb_build_object('ref', v_ref, 'note', left(trim(p_note), 200))
  );
end;
$$;
revoke all on function public.admin_ajouter_note(uuid, text) from public, anon;
grant execute on function public.admin_ajouter_note(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- admin_signaler_litige — pose ou lève le drapeau de litige (indépendant
-- du statut du contrat). Raison obligatoire pour SIGNALER, facultative
-- pour lever.
-- ---------------------------------------------------------------------
create or replace function public.admin_signaler_litige(
  p_contrat uuid, p_actif boolean, p_raison text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_ref text;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_actif and (p_raison is null or length(trim(p_raison)) < 3) then
    raise exception 'Raison obligatoire (min. 3 caractères) pour signaler un litige';
  end if;

  update public.contrats
     set en_litige = p_actif,
         litige_raison = case when p_actif then trim(p_raison) else null end,
         litige_le = case when p_actif then now() else null end,
         litige_par = case when p_actif then auth.uid() else null end
   where id = p_contrat
  returning numero_reference into v_ref;
  if v_ref is null then raise exception 'Contrat introuvable'; end if;

  perform public.admin_logger(
    case when p_actif then 'contrat_litige_signale' else 'contrat_litige_leve' end,
    'contrat', p_contrat::text,
    jsonb_build_object('ref', v_ref, 'raison', p_raison)
  );
end;
$$;
revoke all on function public.admin_signaler_litige(uuid, boolean, text) from public, anon;
grant execute on function public.admin_signaler_litige(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- admin_annuler_contrat — enveloppe admin autour de
-- annuler_contrat_pharmacie (SQL 09, calcul de pénalité inchangé, déjà
-- ouvert à l'admin) : ajoute une raison obligatoire + journalisation
-- centralisée. Ne duplique PAS la logique métier existante.
-- ---------------------------------------------------------------------
create or replace function public.admin_annuler_contrat(p_contrat uuid, p_raison text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_ref text; v_resultat jsonb;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_raison is null or length(trim(p_raison)) < 3 then
    raise exception 'Raison obligatoire (min. 3 caractères) pour annuler depuis la console';
  end if;

  select numero_reference into v_ref from public.contrats where id = p_contrat;
  if v_ref is null then raise exception 'Contrat introuvable'; end if;

  v_resultat := public.annuler_contrat_pharmacie(p_contrat);

  perform public.admin_logger(
    'contrat_annule_admin', 'contrat', p_contrat::text,
    jsonb_build_object('ref', v_ref, 'raison', trim(p_raison), 'resultat', v_resultat)
  );

  return v_resultat;
end;
$$;
revoke all on function public.admin_annuler_contrat(uuid, text) from public, anon;
grant execute on function public.admin_annuler_contrat(uuid, text) to authenticated;
