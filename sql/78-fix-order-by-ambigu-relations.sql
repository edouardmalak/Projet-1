-- =====================================================================
-- C-DIRECT · SQL 78 — correctif : « column reference is ambiguous »
-- dans les deux fonctions de listage des relations (sql/61).
--
-- Cause : le ORDER BY nommait une colonne (nom_pharmacie, prenom, nom)
-- qui existe À LA FOIS comme colonne de sortie de la fonction
-- (RETURNS TABLE) et comme colonne de la table public.profiles jointe
-- dans la requête. PostgreSQL ne peut pas trancher et lève l'erreur
-- « column reference "nom_pharmacie" is ambiguous » — la page
-- pharmacies-preferees.html (locum) et locums-confiance.html
-- (pharmacie) n'affichaient donc aucune relation.
--
-- Correctif : trier par POSITION dans le select (order by 2), comme le
-- fait déjà lister_pharmacies_candidatees (sql/62b). Aucun autre
-- changement : corps, sécurité, droits et colonnes retournées sont
-- identiques à sql/61.
--
-- Note : le message d'erreur est écrit 'Acc'||chr(232)||'s refus'||chr(233)
-- — chr(232) = è, chr(233) = é. Le texte affiché reste exactement
-- « Accès refusé » ; cette écriture sans accent permet de coller le
-- script dans l'éditeur SQL de Supabase sans risque de corruption.
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

create or replace function public.lister_relations_locum()
returns table (pharmacie_id uuid, nom_pharmacie text, ville text, state text, note_moyenne numeric, note_nombre bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacien' then raise exception '%', 'Acc'||chr(232)||'s refus'||chr(233); end if;
  return query
    select p.id, coalesce(nullif(p.nom_pharmacie,''), p.ville, 'Pharmacie'), p.ville, l.state,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.locum_pharmacy_relations l
      join public.profiles p on p.id = l.pharmacie_id
     where l.pharmacien_id = auth.uid()
     order by l.state, 2;
end;
$$;
revoke all on function public.lister_relations_locum() from public, anon;
grant execute on function public.lister_relations_locum() to authenticated;

create or replace function public.lister_relations_pharmacie()
returns table (pharmacien_id uuid, nom text, prenom text, ville_base text, state text, note_moyenne numeric, note_nombre bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacie' then raise exception '%', 'Acc'||chr(232)||'s refus'||chr(233); end if;
  return query
    select p.id, p.nom, p.prenom, p.ville_base, f.state,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.favoris_pharmaciens f
      join public.profiles p on p.id = f.pharmacien_id
     where f.pharmacie_id = auth.uid()
     order by f.state, 3, 2;
end;
$$;
revoke all on function public.lister_relations_pharmacie() from public, anon;
grant execute on function public.lister_relations_pharmacie() to authenticated;
