-- =====================================================================
-- C-DIRECT · SQL 38 — Dispensaire (fil d'articles) : table + RLS
-- Feuille vide au lancement : personne n'écrit de faux contenu à votre
-- place. L'admin ajoute des articles depuis /admin-articles.html ; les
-- pharmaciens et pharmacies les lisent depuis /dispensaire.html (seuls
-- les articles publiés apparaissent côté lecteur).
-- À exécuter dans Supabase → SQL Editor.
-- =====================================================================

create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  titre text not null,
  categorie text not null check (categorie in ('carriere','finances','patients')),
  corps text not null,
  publie boolean not null default false,
  cree_par uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.articles enable row level security;

-- Lecture : tout utilisateur connecté voit les articles publiés ;
-- l'admin voit tout (y compris les brouillons, pour prévisualiser).
drop policy if exists articles_lecture on public.articles;
create policy articles_lecture on public.articles
  for select using (publie = true or public.est_admin());

-- Écriture : admin uniquement.
drop policy if exists articles_ecriture_admin on public.articles;
create policy articles_ecriture_admin on public.articles
  for all using (public.est_admin()) with check (public.est_admin());
