-- =====================================================================
-- C-DIRECT · SQL 20 — Profil pharmacien enrichi (jumelage)
-- À exécuter dans Supabase → SQL Editor (idempotent).
--
-- • Ajoute profiles.langues_parlees (langues parlées, distinct de la
--   langue des communications).  competences[] existe déjà.
-- • get_candidats v3 : renvoie AUSSI logiciels, compétences, langues et
--   la réputation (moyenne + nombre d'évaluations révélées) — pour que la
--   pharmacie choisisse selon les compétences, pas juste le tarif.
-- • get_stats_pharmacien : mandats complétés / annulations (fiabilité).
-- =====================================================================

alter table public.profiles add column if not exists langues_parlees text[];

-- ---------------------------------------------------------------------
-- get_candidats v3 — + logiciels / competences / langues / réputation
-- (la pharmacie propriétaire ou un admin uniquement)
-- ---------------------------------------------------------------------
drop function if exists public.get_candidats(uuid);
create function public.get_candidats(p_contrat uuid)
returns table (
  candidature_id uuid, statut text, type_candidature text,
  tarif_propose numeric, heure_debut_proposee time, heure_fin_proposee time,
  distance_km numeric, message text,
  cree_le timestamptz, maj_le timestamptz,
  pharmacien_id uuid, nom text, prenom text, ville_base text,
  logiciels text[], competences text[], langues_parlees text[],
  note_moyenne numeric, note_nombre bigint
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (
    public.est_admin()
    or exists (select 1 from public.contrats k
                where k.id = p_contrat and k.pharmacie_id = auth.uid())
  ) then
    raise exception 'Accès refusé';
  end if;
  return query
    select c.id, c.statut, c.type_candidature,
           c.tarif_propose, c.heure_debut_proposee, c.heure_fin_proposee,
           c.distance_km, c.message,
           c.created_at, c.updated_at,
           p.id, p.nom, p.prenom, p.ville_base,
           p.logiciels, p.competences, p.langues_parlees,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.candidatures c
      join public.profiles p on p.id = c.pharmacien_id
     where c.contrat_id = p_contrat
     order by c.created_at;
end;
$$;
revoke all on function public.get_candidats(uuid) from public, anon;
grant execute on function public.get_candidats(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- get_stats_pharmacien — fiabilité (mandats acceptés → complétés/annulés)
-- ---------------------------------------------------------------------
create or replace function public.get_stats_pharmacien(p_profil uuid)
returns table (completes bigint, annulations bigint, total bigint, taux_completion int)
language sql stable security definer set search_path = public as $$
  with mine as (
    select k.statut
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
    where c.pharmacien_id = p_profil and c.statut = 'accepte'
  )
  select count(*) filter (where statut = 'complete'),
         count(*) filter (where statut = 'annule'),
         count(*),
         coalesce(round(100.0 * count(*) filter (where statut = 'complete')
                        / nullif(count(*) filter (where statut in ('complete','annule')), 0)), 0)::int
  from mine;
$$;
grant execute on function public.get_stats_pharmacien(uuid) to authenticated;
