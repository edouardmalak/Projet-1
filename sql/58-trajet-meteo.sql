-- =====================================================================
-- C-DIRECT · SQL 58 — Fonction "Trajet" : cache météo par FSA
--
-- Nouvelle fonctionnalité (pas dans le build package features 1/3/4 déjà
-- livré) : avant d'accepter un quart d'hiver, le pharmacien voit si la
-- route (aller ET retour) risque d'être dangereuse, calculé à partir de
-- l'horaire Open-Meteo (gratuit, sans clé) pour le FSA de la pharmacie.
--
-- Ce fichier ne touche AUCUNE table/colonne existante — nouvelle table
-- seule. Le cache est écrit par functions/api/meteo.js (Cloudflare Pages
-- Function) avec la clé anon publique, exactement comme le reste du
-- front-end (voir supabase-config.js : la clé anon est déjà publique,
-- la sécurité vient des politiques RLS ci-dessous, pas du secret).
--
-- Portée volontairement étroite : données 100% publiques et non
-- sensibles (prévisions météo), écriture bornée à un FSA valide du
-- Québec (G/H/J + chiffre + lettre — même motif que fsa-qc.js), donc
-- même en cas d'abus le pire cas est une ligne de cache erronée qui se
-- corrige toute seule au prochain rafraîchissement (aucun lien avec
-- l'argent, les RLS métier ou les données personnelles).
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

create table if not exists public.meteo_cache (
  fsa      text primary key check (fsa ~ '^[GHJ][0-9][A-Z]$'),
  lat      numeric not null,
  lng      numeric not null,
  -- horaire : { "AAAA-MM-JJ": [ {min, type, cm, wind, temp}, ... ], ... }
  -- type ∈ 'ice' | 'snow' | 'none' — voir functions/api/meteo.js
  horaire  jsonb not null,
  -- alerte ECCC (verglas/blizzard officiel). [T25 batch1 — commentaire
  -- périmé corrigé] : livré le 2026-08-08 via functions/_lib/eccc-alertes.js
  -- (CAP-XML du Datamart MSC), branché dans functions/api/meteo.js.
  -- classifyRisk() gère toujours le cas null sans erreur.
  alerte   jsonb,
  maj_le   timestamptz not null default now()
);

comment on table public.meteo_cache is
  'Cache météo Open-Meteo par FSA (RTA) québécois, pour la fonction Trajet. Rafraîchi à la demande par functions/api/meteo.js quand la ligne a plus de quelques heures.';

alter table public.meteo_cache enable row level security;

drop policy if exists "meteo_cache lecture publique" on public.meteo_cache;
create policy "meteo_cache lecture publique"
  on public.meteo_cache for select
  using (true);

-- Écriture bornée : n'importe qui (clé anon) peut écrire, mais SEULEMENT
-- une ligne dont la clé ressemble à un vrai FSA québécois (contrainte
-- déjà appliquée par le check ci-dessus ; répétée ici en with check pour
-- que ce soit explicite dans la politique elle-même).
drop policy if exists "meteo_cache ecriture bornee" on public.meteo_cache;
create policy "meteo_cache ecriture bornee"
  on public.meteo_cache for insert
  with check (fsa ~ '^[GHJ][0-9][A-Z]$');

drop policy if exists "meteo_cache maj bornee" on public.meteo_cache;
create policy "meteo_cache maj bornee"
  on public.meteo_cache for update
  using (true)
  with check (fsa ~ '^[GHJ][0-9][A-Z]$');

grant select, insert, update on public.meteo_cache to anon, authenticated;

-- ---------------------------------------------------------------------
-- Vérification rapide après exécution :
--   select * from public.meteo_cache limit 1;  -- doit fonctionner, 0 ligne au départ
--   -- puis ouvrir contrats.html : la 1re requête météo d'un FSA insère sa ligne.
-- ---------------------------------------------------------------------
