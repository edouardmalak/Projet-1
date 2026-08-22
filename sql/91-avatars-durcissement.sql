-- =====================================================================
-- C-DIRECT · SQL 91 — DURCISSEMENT DU BUCKET « avatars » (audit sécurité, phase 1.2)
-- À exécuter dans Supabase → SQL Editor, APRÈS sql/90.
--
-- DEUX CORRECTIFS, AUCUN CHANGEMENT VISIBLE POUR L'USAGER.
--
-- 1) LISTAGE ANONYME DU BUCKET (constat de l'audit du 2026-08-19)
--    sql/65 a créé la politique « avatars_lecture_publique » :
--        for select using (bucket_id = 'avatars')
--    Sans clause `to`, elle s'applique à TOUS les rôles, anon compris.
--    Or un SELECT sur storage.objects n'autorise pas seulement à lire un
--    fichier connu : il autorise aussi à LISTER le bucket. Vérifié en
--    production le 2026-08-19 : POST /storage/v1/object/list/avatars sans
--    aucune session répond 200. Le bucket étant vide, la liste est vide —
--    mais dès qu'un locum dépose une photo, n'importe qui peut énumérer
--    les noms de dossiers, qui sont les UUID des usagers.
--
--    La politique est INUTILE à l'affichage : le bucket est « public »,
--    donc /storage/v1/object/public/avatars/... est servi sans
--    autorisation ni RLS (c'est la définition même de l'option publique
--    dans le tableau de bord). profil.html n'utilise que getPublicUrl()
--    et upload() — jamais list(). La retirer ne change donc rien à
--    l'affichage des photos, et supprime l'énumération.
--
--    Les 3 politiques d'écriture de sql/65 (insert/update/delete limitées
--    au dossier <uid>) restent en place, INCHANGÉES.
--
-- 2) VALIDATION SERVEUR DES TÉLÉVERSEMENTS (tâche 2.3 du handoff)
--    profil.html filtre déjà accept="image/png,image/jpeg,image/webp" et
--    refuse au-delà de 2 Mo — mais ces deux contrôles sont dans le
--    navigateur, donc contournables, et contentType provient du fichier
--    lui-même. Côté serveur le bucket acceptait « Any » jusqu'à 50 Mo.
--    On aligne le serveur sur ce que l'interface promet déjà.
--
--    2 Mo = 2 * 1024 * 1024 = 2097152 octets — exactement la limite
--    testée dans profil.html, pour que le serveur applique la promesse
--    faite à l'usager.
--
--    image/svg+xml est VOLONTAIREMENT exclu : un SVG est une image qui
--    peut transporter du script, seul format d'image dangereux dans un
--    bucket public.
--
-- Idempotent. Réversible : voir le bloc ANNULATION en fin de fichier.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Retirer le listage public (l'affichage des photos n'en dépend pas)
-- ---------------------------------------------------------------------
drop policy if exists "avatars_lecture_publique" on storage.objects;

-- ---------------------------------------------------------------------
-- 2) Contraindre taille et types au niveau du bucket (contrôle serveur)
-- ---------------------------------------------------------------------
update storage.buckets
   set file_size_limit   = 2097152,
       allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp']
 where id = 'avatars';

-- ---------------------------------------------------------------------
-- VÉRIFICATION (doit renvoyer 2097152 et les 3 types)
--   select id, public, file_size_limit, allowed_mime_types
--     from storage.buckets where id = 'avatars';
--
-- Et le listage anonyme doit désormais échouer :
--   POST /storage/v1/object/list/avatars  →  400/401 au lieu de 200
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- ANNULATION (revenir exactement à l'état d'avant) :
--
--   create policy "avatars_lecture_publique" on storage.objects
--     for select using (bucket_id = 'avatars');
--
--   update storage.buckets
--      set file_size_limit = null, allowed_mime_types = null
--    where id = 'avatars';
-- ---------------------------------------------------------------------
