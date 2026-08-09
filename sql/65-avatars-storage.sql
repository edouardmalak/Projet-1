-- =====================================================================
-- C-DIRECT · SQL 65 — Stockage des photos de profil (facultatives)
--
-- Crée le bucket public « avatars » + les politiques d'accès. La colonne
-- profiles.photo_url existe déjà (sql/42). La photo est FACULTATIVE côté
-- site (profil.html) : ce fichier ne rend rien obligatoire, il ouvre
-- seulement la possibilité de téléverser une image.
--
-- Chemin des fichiers : « <uid>/photo.<ext> » — chaque usager ne peut
-- écrire que dans son propre dossier (le 1er segment doit être son uid).
-- Lecture publique (l'URL de la photo doit s'afficher pour la pharmacie
-- et l'admin). À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

-- Lecture publique des avatars
drop policy if exists "avatars_lecture_publique" on storage.objects;
create policy "avatars_lecture_publique" on storage.objects
  for select using (bucket_id = 'avatars');

-- Un usager connecté ne peut téléverser que dans SON dossier (<uid>/…)
drop policy if exists "avatars_ecriture_proprietaire" on storage.objects;
create policy "avatars_ecriture_proprietaire" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- … et ne peut modifier / remplacer que ses propres fichiers
drop policy if exists "avatars_maj_proprietaire" on storage.objects;
create policy "avatars_maj_proprietaire" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- … et supprimer que les siens
drop policy if exists "avatars_suppression_proprietaire" on storage.objects;
create policy "avatars_suppression_proprietaire" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- Vérification : le bucket doit exister et être public.
--   select id, public from storage.buckets where id = 'avatars';
-- ---------------------------------------------------------------------
