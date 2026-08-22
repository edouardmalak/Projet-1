-- =====================================================================
-- C-DIRECT · SQL 94 — BUCKET « avatars » RENDU PRIVÉ
-- À exécuter dans Supabase → SQL Editor, APRÈS sql/93.
-- ⚠️ À exécuter APRÈS le déploiement de profil.html (URL signées), sinon
--    les photos existantes cesseraient de s'afficher entre les deux.
--
-- POURQUOI
--   sql/91 a retiré la politique de lecture publique, et le listage anonyme
--   a CONTINUÉ de répondre 200 : un bucket `public = true` court-circuite RLS
--   pour la lecture, listage compris. Mesuré en production le 2026-08-22.
--   Tant que le bucket est public, n'importe qui peut donc énumérer les noms
--   de dossiers — c'est-à-dire les UUID des usagers ayant déposé une photo,
--   et donc leur nombre.
--
--   Le bucket n'a jamais eu besoin d'être public : `photo_url` n'apparaît
--   QUE dans profil.html, la page de l'usager lui-même. Aucune fonction RPC
--   ne l'expose et aucun autre écran n'affiche la photo d'autrui.
--
-- CE QUE ÇA CHANGE
--   · lecture par URL publique : terminée
--   · profil.html demande désormais une URL signée (1 h) — déjà déployé
--   · profiles.photo_url contient le CHEMIN (« <uid>/photo.jpg ») ; les
--     anciennes valeurs en URL complète restent affichées telles quelles
--   · le bucket est VIDE au moment de ce changement : aucune photo à migrer
--
-- POLITIQUE DE LECTURE
--   Un bucket privé exige une politique SELECT pour signer une URL. On la
--   limite au PROPRIÉTAIRE — c'est exactement l'usage actuel.
--   ⚠️ Le jour où une pharmacie ou l'admin devra voir la photo d'un locum
--      (c'était l'intention d'origine de sql/65, jamais implémentée), il
--      faudra ÉLARGIR cette politique — et non repasser le bucket en public.
--
-- Les 3 politiques d'écriture de sql/65 (insert/update/delete limitées au
-- dossier <uid>) restent INCHANGÉES.
--
-- Idempotent. Annulation en fin de fichier.
-- =====================================================================

update storage.buckets
   set public = false
 where id = 'avatars';

drop policy if exists "avatars_lecture_proprietaire" on storage.objects;
create policy "avatars_lecture_proprietaire" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- VÉRIFICATION
--   1) le bucket est privé :
--        select id, public from storage.buckets where id = 'avatars';
--   2) le listage anonyme doit maintenant ÉCHOUER (il répondait 200) :
--        POST /storage/v1/object/list/avatars  sans session  ->  400/401
--   3) téléverser une photo depuis /profil et vérifier qu'elle s'affiche
--      toujours (URL signée) après rechargement de la page.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- ANNULATION (revenir à l'état d'avant) :
--   update storage.buckets set public = true where id = 'avatars';
--   drop policy if exists "avatars_lecture_proprietaire" on storage.objects;
--   create policy "avatars_lecture_publique" on storage.objects
--     for select using (bucket_id = 'avatars');
--   (et redéployer la version de profil.html qui utilise getPublicUrl)
-- ---------------------------------------------------------------------
