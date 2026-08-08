-- =====================================================================
-- C-DIRECT · SQL 62 — pendant, côté locum, de lister_pharmaciens_deja_postules
-- (sql/59) : les pharmacies auxquelles ce pharmacien a déjà soumis une
-- candidature, avec son état de relation actuel. Sert la page
-- pharmacies-preferees.html (section "ajouter") — même discipline de vie
-- privée que sql/59 : aucune recherche ouverte, uniquement des pharmacies
-- avec lesquelles une relation existe déjà (candidature soumise).
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

create or replace function public.lister_pharmacies_candidatees()
returns table (
  pharmacie_id uuid, nom_pharmacie text, ville text,
  note_moyenne numeric, note_nombre bigint, deja_favori boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacien' then raise exception 'Accès refusé'; end if;
  return query
    select distinct p.id, coalesce(nullif(p.nom_pharmacie,''), p.ville, 'Pharmacie'), p.ville,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g),
           exists(select 1 from public.locum_pharmacy_relations l
                   where l.pharmacien_id = auth.uid() and l.pharmacie_id = p.id and l.state = 'favorite')
      from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      join public.profiles p on p.id = k.pharmacie_id
     where c.pharmacien_id = auth.uid()
       and not public.est_bloque(auth.uid(), p.id)
       and not exists (select 1 from public.locum_pharmacy_relations l2
                         where l2.pharmacien_id = auth.uid() and l2.pharmacie_id = p.id and l2.state in ('muted','blocked'))
     order by 2;
end;
$$;
revoke all on function public.lister_pharmacies_candidatees() from public, anon;
grant execute on function public.lister_pharmacies_candidatees() to authenticated;
