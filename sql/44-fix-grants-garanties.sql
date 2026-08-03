-- =====================================================================
-- C-DIRECT · PAIEMENTS STRIPE · SQL 44 — CORRECTIF GRANTS
-- À exécuter APRÈS sql/43-garanties-paiement.sql, dans Supabase → SQL Editor.
--
-- Bug trouvé en testant le cycle de bout en bout (contrat CD-100094) :
-- sql/43 faisait `revoke all ... from public, anon, authenticated` sur les
-- trois RPC lister_* SANS jamais faire le `grant execute ... to service_role`
-- correspondant. Le rôle service_role N'HÉRITE PAS automatiquement du
-- privilège EXECUTE retiré de PUBLIC — ce n'est pas RLS (que service_role
-- contourne bien), c'est une permission d'exécution de fonction séparée.
-- Résultat concret : le Worker appelait ces RPC via REST, recevait une
-- erreur "permission denied for function...", et mon code prenait ça pour
-- un tableau vide (`Array.isArray(x) ? x : []`) — donc AUCUNE autorisation
-- n'était jamais créée, sans la moindre erreur visible côté site.
-- =====================================================================

grant execute on function public.lister_candidatures_a_autoriser(int) to service_role;
grant execute on function public.lister_echeances_a_fixer() to service_role;
grant execute on function public.lister_garanties_a_capturer() to service_role;

-- Vérification : ce SELECT doit fonctionner sans erreur (exécuté ici avec
-- les droits du SQL Editor, qui est superutilisateur — le vrai test est
-- que le Worker cesse de recevoir une erreur 403/permission denied) :
-- select * from public.lister_candidatures_a_autoriser();
