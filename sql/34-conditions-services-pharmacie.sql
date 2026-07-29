-- =====================================================================
-- C-DIRECT · SQL 34 — Conditions par défaut + services offerts (profil pharmacie)
-- Permet à la pharmacie de régler une fois pour toutes : seul(e) pharmacien(ne),
-- ATP présente, et les services habituellement requis — au lieu de les
-- re-remplir à chaque publication de contrat (voir profil.html / bloc pharmacie).
-- À exécuter dans Supabase → SQL Editor.
-- =====================================================================

alter table public.profiles add column if not exists seul_pharmacien boolean not null default true;
alter table public.profiles add column if not exists atp_presente boolean not null default true;
alter table public.profiles add column if not exists services_offerts text[] not null default '{}';
