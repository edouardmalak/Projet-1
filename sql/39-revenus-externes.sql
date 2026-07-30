-- =====================================================================
-- C-DIRECT · SQL 39 — Revenus hors C-Direct (pharmacien)
-- Portée volontairement étroite : uniquement le revenu gagné EN DEHORS
-- de C-Direct (un autre remplacement, un poste salarié, etc.), pour que
-- le total annuel et l'export T2125 reflètent l'ensemble de l'année, pas
-- seulement les mandats C-Direct. PAS de dépenses générales d'entreprise
-- ici (assurance, cours, cellulaire) — décision explicite du 29 juillet :
-- portée limitée au revenu externe uniquement.
-- À exécuter dans Supabase → SQL Editor.
-- =====================================================================

create table if not exists public.revenus_externes (
  id uuid primary key default gen_random_uuid(),
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  date_revenu date not null,
  description text,
  montant numeric not null check (montant >= 0),
  km numeric,
  notes text,
  created_at timestamptz not null default now()
);

alter table public.revenus_externes enable row level security;

drop policy if exists revenus_externes_self on public.revenus_externes;
create policy revenus_externes_self on public.revenus_externes
  for all using (auth.uid() = pharmacien_id) with check (auth.uid() = pharmacien_id);
