-- =====================================================================
-- C-DIRECT · SQL 35 — Horaires d'ouverture, plafonds de frais, favoris
-- et confirmation automatique ("Instant Booking") pour la pharmacie.
-- À exécuter dans Supabase → SQL Editor.
--
-- NOTE : une table public.favoris existe déjà (pharmacien_id, contrat_id —
-- contrats sauvegardés par un pharmacien). Ceci est un concept différent
-- (pharmacie -> pharmaciens favoris) : nouvelle table favoris_pharmaciens
-- pour éviter toute confusion/collision avec l'existant.
-- =====================================================================

-- ---------- Horaires d'ouverture (pharmacie) ----------
-- Un objet JSON par jour, ex. {"lun":{"ouvre":"08:00","ferme":"21:00","ferme_jour":false}, ...}
-- Purement informatif pour l'instant (affiché au profil, pas encore utilisé pour filtrer).
alter table public.profiles add column if not exists horaires_ouverture jsonb;

-- ---------- Plafonds de frais (pharmacie) ----------
-- Montants maximums que la pharmacie accepte de payer (déplacement, per diem,
-- hébergement). Informatifs pour l'instant : PAS encore branchés sur le calcul
-- des factures (qui reste basé sur regles_reseau + distance) tant que ce n'est
-- pas confirmé explicitement.
alter table public.profiles add column if not exists plafond_deplacement numeric;
alter table public.profiles add column if not exists plafond_per_diem numeric;
alter table public.profiles add column if not exists plafond_hebergement numeric;

-- ---------- Confirmation automatique des favoris ("Instant Booking") ----------
-- Off par défaut : rien ne change tant que la pharmacie ne l'active pas
-- elle-même dans son profil.
alter table public.profiles add column if not exists confirmation_auto_favoris boolean not null default false;

-- ---------- Favoris : pharmacie -> pharmaciens ----------
create table if not exists public.favoris_pharmaciens (
  pharmacie_id  uuid not null references public.profiles(id) on delete cascade,
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (pharmacie_id, pharmacien_id)
);
alter table public.favoris_pharmaciens enable row level security;

drop policy if exists favoris_pharmaciens_gestion on public.favoris_pharmaciens;
create policy favoris_pharmaciens_gestion on public.favoris_pharmaciens
  for all using (auth.uid() = pharmacie_id) with check (auth.uid() = pharmacie_id);

-- Le pharmacien peut voir s'il est favori quelque part (lecture seule, pas de fuite du reste)
drop policy if exists favoris_pharmaciens_lecture_pharmacien on public.favoris_pharmaciens;
create policy favoris_pharmaciens_lecture_pharmacien on public.favoris_pharmaciens
  for select using (auth.uid() = pharmacien_id);
