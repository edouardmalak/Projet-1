-- =====================================================================
-- Enumeration du schema LIVE — a executer dans Supabase > SQL Editor.
-- Sert a verifier que la matrice d audit couvre TOUTES les tables reelles
-- (le handoff exige la liste depuis la base, jamais depuis les fichiers).
-- Lecture seule : n ajoute AUCUNE fonction ni droit a la base.
-- Compare le resultat a la liste testee dans PHASE1-RESULTATS.md §2c.
-- =====================================================================
select string_agg(c.relname, ', ' order by c.relname)
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind = 'r';
