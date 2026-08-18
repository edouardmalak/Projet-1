-- =====================================================================
-- 81 — VIDAGE COMPLET DES DONNÉES DE TEST (« comme au jour du lancement »)
-- =====================================================================
-- Contexte (2026-08-18) : avant le premier test de paiement avec de
-- l'argent réel, on repart d'une base propre. Tout ce qui a été créé en
-- essayant le site (contrats, candidatures, garanties, factures, files
-- SMS, évaluations…) est effacé. Les COMPTES et la configuration
-- restent — sinon il faudrait tout réinscrire et réenregistrer la carte.
--
-- Point de restauration git avant exécution :
--   restore-2026-08-18-avant-flush-tests
--
-- ⚠️ DESTRUCTIF ET IRRÉVERSIBLE côté base. À n'exécuter qu'une fois.
-- =====================================================================
--
-- CE QUI EST EFFACÉ
--   contrats                      (+ tout ce qui en dépend, en cascade :)
--     └ candidatures
--         └ factures
--         └ garanties_paiement
--             └ garanties_paiement_journal
--     └ contrat_notes_admin, demandes_contrat, demandes_retard,
--       evaluations, favoris (quarts mis en favori), fiabilite_annonce,
--       match_log, messages, sms_queue
--   fils                          (conversations — contrat_id passait à NULL)
--   sms_log, sms_batch            (historique d'envois de test)
--   matching_queue                (évènements d'auto-acceptation en attente)
--   annulations_auto_acceptation
--   rendez_vous                   (demandes d'entrevue de test)
--   stripe_evenements             (journal anti-doublon des webhooks)
--   file_notifications, verification_interac
--   + le compteur CD-1000xx repart à CD-100001
--
-- CE QUI EST CONSERVÉ (volontairement)
--   profiles                      les comptes et leurs approbations
--   stripe_comptes                la carte de garantie de la pharmacie et
--                                 le compte connecté du pharmacien —
--                                 les effacer casserait le test à venir
--   disponibilites                calendrier des pharmaciens (règle : on
--                                 n'y touche jamais sans accord explicite)
--   locum_calendar_confirmations  rattaché au même calendrier
--   favoris_pharmaciens, locum_pharmacy_relations, exclusions
--   regles_reseau, auto_accept_admin_settings, articles,
--   push_subscriptions, fsa_centroides, admin_audit_log
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- AVANT — photo de l'état actuel (lecture seule)
-- ---------------------------------------------------------------------
select 'AVANT' as etape,
       (select count(*) from public.contrats)                   as contrats,
       (select count(*) from public.candidatures)               as candidatures,
       (select count(*) from public.garanties_paiement)         as garanties,
       (select count(*) from public.garanties_paiement_journal) as journal,
       (select count(*) from public.factures)                   as factures,
       (select count(*) from public.fils)                       as fils,
       (select count(*) from public.messages)                   as messages,
       (select count(*) from public.sms_queue)                  as sms_en_file,
       (select count(*) from public.sms_log)                    as sms_journal,
       (select count(*) from public.matching_queue)             as file_matching,
       (select count(*) from public.stripe_evenements)          as evenements_stripe,
       (select count(*) from public.profiles)                   as comptes_conserves,
       (select count(*) from public.stripe_comptes)             as stripe_comptes_conserves;

-- ---------------------------------------------------------------------
-- 1) LE CŒUR — effacer les contrats emporte en cascade candidatures,
--    factures, garanties + journal, évaluations, messages, sms_queue,
--    demandes, notes admin et favoris de quarts (contraintes ON DELETE
--    CASCADE déjà en place — vérifiées avant écriture de ce script).
-- ---------------------------------------------------------------------
delete from public.contrats;

-- ---------------------------------------------------------------------
-- 2) LES RESTES — tables dont la clé passait à NULL (ON DELETE SET NULL)
--    au lieu d'être supprimées, ou sans lien direct au contrat.
-- ---------------------------------------------------------------------
delete from public.garanties_paiement_journal;   -- filet (orphelins impossibles)
delete from public.garanties_paiement;           -- filet
delete from public.factures;                     -- filet
delete from public.candidatures;                 -- filet
delete from public.messages;                     -- avant fils (FK fil_id)
delete from public.fils;                         -- conversations de test
delete from public.sms_queue;                    -- y compris les diffusions sans contrat
delete from public.sms_log;                      -- historique d'envois de test
delete from public.sms_batch;
delete from public.matching_queue;               -- évènements auto-acceptation en attente
delete from public.annulations_auto_acceptation;
delete from public.rendez_vous;                  -- demandes d'entrevue de test
delete from public.stripe_evenements;            -- journal anti-doublon des webhooks
delete from public.file_notifications;
delete from public.verification_interac;
delete from public.demandes_retard;
delete from public.demandes_contrat;
delete from public.contrat_notes_admin;
delete from public.evaluations;
delete from public.fiabilite_annonce;
delete from public.match_log;

-- ---------------------------------------------------------------------
-- 3) Le compteur de références repart au début : le premier vrai contrat
--    portera le numéro CD-100001 (et non CD-100098).
-- ---------------------------------------------------------------------
select setval('public.contrats_ref_seq', 100001, false);

-- ---------------------------------------------------------------------
-- APRÈS — vérification : tout doit être à 0 sauf les deux dernières
-- colonnes (comptes et comptes Stripe, qui doivent être INCHANGÉS).
-- ---------------------------------------------------------------------
select 'APRES' as etape,
       (select count(*) from public.contrats)                   as contrats,
       (select count(*) from public.candidatures)               as candidatures,
       (select count(*) from public.garanties_paiement)         as garanties,
       (select count(*) from public.garanties_paiement_journal) as journal,
       (select count(*) from public.factures)                   as factures,
       (select count(*) from public.fils)                       as fils,
       (select count(*) from public.messages)                   as messages,
       (select count(*) from public.sms_queue)                  as sms_en_file,
       (select count(*) from public.sms_log)                    as sms_journal,
       (select count(*) from public.matching_queue)             as file_matching,
       (select count(*) from public.stripe_evenements)          as evenements_stripe,
       (select count(*) from public.profiles)                   as comptes_conserves,
       (select count(*) from public.stripe_comptes)             as stripe_comptes_conserves;

commit;
