-- =====================================================================
-- C-DIRECT · SQL 22 — PURGE DES DONNÉES DE TEST (avant lancement)
-- Vérifié le 2026-07-23 : cible exactement les 2 contrats TEST-COWORK.
-- À exécuter dans Supabase → SQL Editor. IRRÉVERSIBLE — relire d'abord.
--
-- Les 2 COMPTES de test (edouardmalak+pharmacien@ / +pharmacie@) se
-- suppriment séparément dans Authentication → Users (cascade via la FK
-- profiles). Ne PAS supprimer edouardmalak@gmail.com (votre compte admin).
-- =====================================================================

with cibles as (
  select id from public.contrats
   where numero_reference in ('CD-100012','CD-100013')
      or notes ilike 'TEST-COWORK%'
)
-- 1) factures rattachées aux candidatures de ces contrats
delete from public.factures f
 using public.candidatures c
 where f.candidature_id = c.id
   and c.contrat_id in (select id from cibles);

with cibles as (
  select id from public.contrats
   where numero_reference in ('CD-100012','CD-100013')
      or notes ilike 'TEST-COWORK%'
)
-- 2) candidatures de ces contrats
delete from public.candidatures
 where contrat_id in (select id from cibles);

-- 3) les contrats de test eux-mêmes
delete from public.contrats
 where numero_reference in ('CD-100012','CD-100013')
    or notes ilike 'TEST-COWORK%';

-- 4) vérification : plus aucune ligne « test » ne doit apparaître
select numero_reference, statut, notes
  from public.contrats
 order by created_at;
