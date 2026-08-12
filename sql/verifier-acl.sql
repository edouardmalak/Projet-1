-- =====================================================================
-- verifier-acl.sql — T27 (batch1) : contrôle récurrent des ACL fonctions
-- ---------------------------------------------------------------------
-- POURQUOI : Postgres accorde EXECUTE à PUBLIC par défaut sur toute
-- nouvelle fonction. Un simple CREATE OR REPLACE (ou DROP+CREATE) sans
-- REVOKE rouvre donc l'accès anonyme — c'est exactement la classe de
-- fuite corrigée par sql/63 (get_stats_pharmacien / get_note_profil,
-- découverte en testant à la main).
--
-- QUAND L'EXÉCUTER : après CHAQUE nouvelle migration sql/NN-*.sql,
-- dans Supabase > SQL Editor. Résultat attendu : ZÉRO ligne.
-- Toute ligne listée = une fonction que le rôle `anon` (donc n'importe
-- qui, sans session) peut exécuter — à corriger immédiatement par :
--   revoke all on function public.<nom>(<args>) from public, anon;
--   grant execute on function public.<nom>(<args>) to authenticated; -- si voulu
-- =====================================================================

select n.nspname                                    as schema,
       p.proname                                    as fonction,
       pg_get_function_identity_arguments(p.oid)    as arguments,
       case when p.prosecdef then 'SECURITY DEFINER' else 'invoker' end as securite
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and has_function_privilege('anon', p.oid, 'execute')
 order by p.proname;

-- Résultat attendu : zéro ligne. (has_function_privilege('anon', …)
-- couvre aussi les droits hérités du pseudo-rôle PUBLIC.)
