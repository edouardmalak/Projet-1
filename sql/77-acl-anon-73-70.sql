-- =====================================================================
-- 77 — T27 (batch1, suite immédiate) : fuites anon détectées par
--       sql/verifier-acl.sql à sa PREMIÈRE exécution (2026-08-12)
-- ---------------------------------------------------------------------
-- Régression de la classe « migration 63 » :
--   · sql/73 a recréé get_contrats_ouverts() et get_contrat_fiche(text)
--     avec `grant ... to authenticated` mais SANS le
--     `revoke all ... from public, anon` qu'il applique pourtant à
--     marquer_complete() et calculer_montant_locum() (lignes 176/230).
--     Postgres accorde EXECUTE à PUBLIC par défaut → le rôle anon
--     pouvait appeler ces deux RPC SECURITY DEFINER sans session et
--     lire la liste complète des contrats ouverts (pharmacies, tarifs,
--     villes) ainsi que toute fiche par référence.
--   · sql/70 n'a jamais posé d'ACL sur aa_horaire_libre(uuid, uuid).
-- Correctif : même recette que sql/63.
-- =====================================================================

revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

revoke all on function public.aa_horaire_libre(uuid, uuid) from public, anon;
grant execute on function public.aa_horaire_libre(uuid, uuid) to authenticated;

-- Vérification (doit revenir à zéro ligne SECURITY DEFINER non-trigger) :
--   voir sql/verifier-acl.sql
