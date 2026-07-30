-- =====================================================================
-- C-DIRECT · SQL 40 — Candidatures en attente pour l'onglet « Demandé »
-- de Mes mandats (pharmacien). À exécuter dans Supabase → SQL Editor.
--
-- get_mes_mandats() (sql/07) ne renvoie que les candidatures ACCEPTÉES
-- (c.statut = 'accepte') : le pharmacien n'a donc aucun moyen de voir,
-- sur cette page, les candidatures encore en attente d'une réponse de
-- la pharmacie ('propose' ou 'contre_offre'). Cette fonction comble ce
-- trou, sur le même modèle (SECURITY DEFINER, RLS déjà en place sur
-- candidatures/contrats empêcherait une jointure directe côté client
-- vers profiles).
-- =====================================================================

create or replace function public.get_mes_candidatures_en_attente()
returns table (
  contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif numeric,
  candidature_statut text, nom_pharmacie text, ville text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           coalesce(c.heure_debut_proposee, k.heure_debut),
           coalesce(c.heure_fin_proposee,  k.heure_fin),
           coalesce(c.tarif_propose, k.tarif_horaire),
           c.statut, pe.nom_pharmacie, pe.ville
      from public.candidatures c
      join public.contrats k  on k.id = c.contrat_id
      join public.profiles pe on pe.id = k.pharmacie_id
     where c.pharmacien_id = auth.uid()
       and c.statut in ('propose','contre_offre')
     order by k.date_contrat asc;
end;
$$;
revoke all on function public.get_mes_candidatures_en_attente() from public, anon;
grant execute on function public.get_mes_candidatures_en_attente() to authenticated;
