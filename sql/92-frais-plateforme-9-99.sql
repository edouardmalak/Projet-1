-- =====================================================================
-- C-DIRECT · SQL 92 — FRAIS DE PLATEFORME : 0 $ -> 9,99 $ PAR QUART
-- À exécuter dans Supabase → SQL Editor, APRÈS sql/91.
--
-- POURQUOI CE FICHIER EXISTE
--   L'audit de sécurité du 2026-08-19 a constaté, en interrogeant la
--   production, que frais_plateforme() renvoyait 0 : sql/82 sème la ligne
--   à 0 (« 0 $ pour la phase de test ») avec `on conflict do nothing`, et
--   personne ne l'a jamais remontée. Lancer dans cet état facturerait
--   0 $ de frais sur CHAQUE quart.
--
-- VALEUR RETENUE : 9,99 $ — demandée explicitement par Robert le
--   2026-08-22. À noter : la documentation du projet (analyse
--   concurrentielle « Pas une agence », seuil de rentabilité de
--   5,13 quarts/mois) est bâtie sur 39 $/quart, et la valeur par défaut
--   de la colonne est encore 39. Ce fichier ne change QUE la ligne de
--   données, pas le défaut de la colonne ni aucun calcul.
--
-- POURQUOI UN UPDATE DIRECT PLUTÔT QUE modifier_frais_plateforme()
--   Cette fonction exige est_admin(). Dans le SQL Editor on s'exécute en
--   tant que `postgres`, donc auth.uid() est NULL et est_admin() renverrait
--   faux : l'appel échouerait. L'UPDATE direct déclenche quand même le
--   trigger d'historique (sql/82), donc le changement RESTE journalisé
--   dans parametres_plateforme_history — simplement avec modifie_par NULL,
--   ce qui est exact : la modification vient d'une migration, pas d'un
--   humain connecté.
--
-- AUCUNE LOGIQUE DE PAIEMENT N'EST TOUCHÉE : ni la machine à états des
-- garanties, ni le Worker Stripe, ni le calcul du montant du locum. Seule
-- la valeur lue par frais_plateforme() change.
--
-- Idempotent. Annulation en fin de fichier.
-- =====================================================================

update public.parametres_plateforme
   set frais_cdirect_dollars = 9.99
 where id = 1;

-- ---------------------------------------------------------------------
-- VÉRIFICATION (doit renvoyer 9.99) :
--   select frais_cdirect_dollars from public.parametres_plateforme where id = 1;
--   select public.frais_plateforme();
--
-- Et l'historique doit contenir la trace 0 -> 9.99 :
--   select * from public.parametres_plateforme_history order by modifie_le desc limit 1;
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- ANNULATION (revenir à l'état d'avant, 0 $) :
--   update public.parametres_plateforme set frais_cdirect_dollars = 0 where id = 1;
--
-- POUR PASSER À 39 $ (valeur documentée dans le reste du projet) :
--   update public.parametres_plateforme set frais_cdirect_dollars = 39 where id = 1;
-- ---------------------------------------------------------------------
