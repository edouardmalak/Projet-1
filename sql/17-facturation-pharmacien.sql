-- =====================================================================
-- C-DIRECT · SQL 17 — Champs de facturation du pharmacien (TPS/TVQ/société)
-- À exécuter dans Supabase → SQL Editor (idempotent, sans danger).
--
-- Permet au pharmacien d'inscrire ses numéros de taxes et sa raison
-- sociale (page Profil). Le mandat/facture affiche alors ces numéros et
-- applique les taxes (TPS 5 % + TVQ 9,975 %) — comme votre facture actuelle,
-- qui ne taxe QUE si un numéro de TPS est au dossier.
-- Sans ce fichier, tout fonctionne : les champs restent simplement vides.
-- =====================================================================

alter table public.profiles add column if not exists tps text;
alter table public.profiles add column if not exists tvq text;
alter table public.profiles add column if not exists societe text;
