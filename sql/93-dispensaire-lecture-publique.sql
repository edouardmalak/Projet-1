-- =====================================================================
-- C-DIRECT · SQL 93 — DISPENSAIRE LISIBLE SANS SESSION (référencement)
-- À exécuter dans Supabase → SQL Editor, APRÈS sql/92.
--
-- LE PROBLÈME (constaté en production le 2026-08-19, audit phase 1)
--   La politique de sql/38 est :
--       for select using (publie = true or public.est_admin())
--   Elle a l'air d'ouvrir les articles publiés à tout le monde. En réalité
--   NON : le rôle `anon` n'a pas le droit EXECUTE sur est_admin() (retiré
--   par sql/63, à raison). Postgres évalue quand même la branche OR, se
--   heurte au refus de permission, et fait échouer TOUTE la requête.
--   Résultat mesuré : un visiteur déconnecté reçoit 401 sur /dispensaire,
--   et Google ne voit jamais un seul article.
--
--   Ce n'était pas un trou de sécurité — ça échouait du bon côté — mais
--   c'était l'inverse de l'intention : le dispensaire ne pouvait pas
--   servir de surface de référencement.
--
-- LE CORRECTIF : deux politiques au lieu d'une.
--   Postgres combine les politiques permissives avec OU. En restreignant
--   la politique admin à `authenticated`, le rôle anon ne l'évalue même
--   pas — donc il ne touche jamais est_admin() et n'échoue plus.
--
--   · anon et connectés      -> articles publiés (publie = true)
--   · connectés admin        -> tout, brouillons compris (inchangé)
--
--   Les droits d'ÉCRITURE (articles_ecriture_admin, sql/38) ne sont PAS
--   touchés : l'admin reste seul à pouvoir créer, modifier ou supprimer.
--   Un brouillon (publie = false) reste invisible à tout non-admin.
--
-- Idempotent. Annulation en fin de fichier.
-- =====================================================================

-- L'ancienne politique unique disparaît, remplacée par les deux ci-dessous.
drop policy if exists articles_lecture on public.articles;

-- 1) Articles PUBLIÉS : lisibles par tous, session ou non.
--    JUSTIFICATION de l'accès anon (règle de MIGRATION-RULES) : le
--    dispensaire est une surface publique voulue, destinée au référencement.
--    Aucune donnée personnelle dans cette table — uniquement du contenu
--    éditorial que l'admin a explicitement marqué « publié ».
drop policy if exists articles_lecture_publiee on public.articles;
create policy articles_lecture_publiee on public.articles
  for select using (publie = true);

-- 2) L'admin voit TOUT, brouillons compris.
--    `to authenticated` est essentiel : sans cette restriction, anon
--    évaluerait est_admin() et retomberait dans le bogue corrigé ici.
drop policy if exists articles_lecture_admin on public.articles;
create policy articles_lecture_admin on public.articles
  for select to authenticated using (public.est_admin());

-- ---------------------------------------------------------------------
-- VÉRIFICATION
--   Sans session (curl ou navigation privée), doit renvoyer les articles
--   publiés et AUCUN brouillon :
--     GET /rest/v1/articles?select=titre,publie
--   Connecté en admin : les brouillons doivent réapparaître.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- ANNULATION (revenir exactement à l'état d'avant) :
--   drop policy if exists articles_lecture_publiee on public.articles;
--   drop policy if exists articles_lecture_admin   on public.articles;
--   create policy articles_lecture on public.articles
--     for select using (publie = true or public.est_admin());
-- ---------------------------------------------------------------------
