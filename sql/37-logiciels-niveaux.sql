-- =====================================================================
-- C-DIRECT · SQL 37 — Niveaux de maîtrise par logiciel (0-100%)
-- Ajoute une richesse d'affichage au-dessus du système existant, sans y
-- toucher : la liste binaire profiles.logiciels (« maîtrisé ou non ») reste
-- la seule donnée utilisée par le matching (compter_compatibles, calcMatch
-- côté pharmacien) — purement informatif, personne n'est exclu sur la base
-- du pourcentage. À exécuter dans Supabase → SQL Editor.
-- =====================================================================

alter table public.profiles
  add column if not exists logiciels_niveaux jsonb not null default '{}';

-- ---------------------------------------------------------------------
-- get_candidats — ajoute logiciels_niveaux à la fiche candidat vue par
-- la pharmacie (reprend sql/21 telle quelle + une colonne).
-- ---------------------------------------------------------------------
drop function if exists public.get_candidats(uuid);
create function public.get_candidats(p_contrat uuid)
returns table (
  candidature_id uuid, statut text, type_candidature text,
  tarif_propose numeric, heure_debut_proposee time, heure_fin_proposee time,
  distance_km numeric, message text,
  cree_le timestamptz, maj_le timestamptz,
  pharmacien_id uuid, nom text, prenom text, ville_base text,
  logiciels text[], logiciels_niveaux jsonb, competences text[], langues_parlees text[],
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
           p.logiciels, p.logiciels_niveaux, p.competences, p.langues_parlees,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.candidatures c
      join public.profiles p on p.id = c.pharmacien_id
      join public.contrats  k on k.id = c.contrat_id
     where c.contrat_id = p_contrat
       and (public.est_admin() or not public.est_exclu(c.pharmacien_id, k.pharmacie_id))
     order by c.created_at;
end;
$$;
revoke all on function public.get_candidats(uuid) from public, anon;
grant execute on function public.get_candidats(uuid) to authenticated;
