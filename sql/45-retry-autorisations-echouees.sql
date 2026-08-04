-- =====================================================================
-- C-DIRECT · PAIEMENTS STRIPE · SQL 45 — RETENTATIVE DES ÉCHECS
-- À exécuter APRÈS sql/44-fix-grants-garanties.sql, dans Supabase → SQL Editor.
--
-- Bug de conception trouvé en testant de bout en bout : une fois qu'une
-- candidature obtenait un statut 'authorization_failed' (ex. carte pas
-- encore enregistrée), elle restait bloquée pour TOUJOURS — le filtre
-- `not exists (garanties_paiement...)` l'excluait de tous les cycles
-- suivants, même après correction du problème (carte ajoutée). Il fallait
-- supprimer la ligne à la main pour redonner une chance à la candidature.
--
-- Correctif : lister_candidatures_a_autoriser inclut maintenant aussi les
-- échecs récents (moins de 5 tentatives), et renvoie l'id de la garantie
-- existante si présente pour que le Worker RÉUTILISE la ligne (upsert)
-- plutôt que de tenter un second insert (candidature_id est UNIQUE).
-- Toujours pas la vraie échelle de relance T-18h/carte de secours/SMS —
-- juste « réessayer au prochain cycle si < 5 tentatives » — voir tâche #21
-- pour la vraie échelle avec délais espacés.
-- =====================================================================

create or replace function public.lister_candidatures_a_autoriser(p_fenetre_heures int default 24)
returns table (
  candidature_id uuid, pharmacien_id uuid, pharmacie_id uuid,
  montant_locum numeric, debut_quart timestamptz,
  garantie_id uuid, tentative_precedente int
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select c.id, c.pharmacien_id, k.pharmacie_id,
           public.calculer_montant_locum(c.id),
           (k.date_contrat + coalesce(c.heure_debut_proposee, k.heure_debut))::timestamptz,
           g.id, g.tentative_autorisation
      from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      left join public.garanties_paiement g on g.candidature_id = c.id
     where c.statut = 'accepte'
       and k.statut = 'attribue'
       and (k.date_contrat + coalesce(c.heure_debut_proposee, k.heure_debut))::timestamptz
             between now() and now() + make_interval(hours => p_fenetre_heures)
       and (
         g.id is null                                             -- jamais tenté
         or (g.statut = 'authorization_failed' and g.tentative_autorisation < 5)  -- échec récent, encore des essais
       );
end;
$$;
revoke all on function public.lister_candidatures_a_autoriser(int) from public, anon, authenticated;
grant execute on function public.lister_candidatures_a_autoriser(int) to service_role;

-- Vérification : select * from public.lister_candidatures_a_autoriser();
