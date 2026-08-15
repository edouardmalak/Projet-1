-- =====================================================================
-- 80 — Purge des artefacts Stripe « sandbox » après le passage en LIVE
-- =====================================================================
-- Contexte (2026-08-15) : le Worker c-direct-payments utilise désormais la
-- clé secrète LIVE (sk_live_...). Or la base contient encore des
-- identifiants Stripe créés en mode TEST (compte sandbox
-- acct_1Tz4YURmN5RelCsE). Les deux modes sont des espaces totalement
-- séparés chez Stripe : un identifiant de test n'existe pas en live.
--
-- Symptôme observé : Paramètres → Paiements affiche
--   « Erreur de chargement : No such customer: 'cus_UzTijgEyhLkHVN' »
-- parce que routeSetupIntent() réutilise stripe_comptes.stripe_customer_id
-- s'il est présent, et demande ce customer à Stripe en mode live.
--
-- Ce script EFFACE ces identifiants périmés. Le Worker en recrée
-- automatiquement des neufs, en live, au prochain usage :
--   - pharmacie  → nouveau customer plateforme à l'ouverture de l'onglet
--                  Paiements (routeSetupIntent, `if (!customerId)`)
--   - pharmacien → nouveau compte connecté Express au prochain
--                  onboarding (routeOnboardingStart)
--
-- IDEMPOTENT : peut être relancé sans risque.
-- À n'exécuter QU'UNE FOIS le passage en live effectué (sinon on efface
-- des identifiants de test encore utilisés).
-- =====================================================================

-- ---------------------------------------------------------------------
-- AVANT — état actuel (lecture seule, ne modifie rien)
-- ---------------------------------------------------------------------
select 'AVANT — stripe_comptes' as etape,
       count(*)                                            as lignes,
       count(stripe_customer_id)                           as avec_customer,
       count(stripe_account_id)                            as avec_compte_connecte
from public.stripe_comptes;

select 'AVANT — garanties actives' as etape,
       statut,
       count(*) as lignes
from public.garanties_paiement
where statut in ('awaiting_authorization','authorized',
                 'pending_locum_confirmation','amount_mismatch')
group by statut
order by statut;

-- ---------------------------------------------------------------------
-- PARTIE A — identifiants Stripe périmés (la correction du blocage)
-- ---------------------------------------------------------------------
-- On vide les colonnes plutôt que de supprimer les lignes : la relation
-- profil_id reste intacte, et le Worker (service_role) réécrit par upsert.
update public.stripe_comptes
set stripe_customer_id    = null,
    stripe_account_id     = null,
    stripe_account_statut = null,
    updated_at            = now()
where stripe_customer_id is not null
   or stripe_account_id is not null
   or stripe_account_statut is not null;

-- ---------------------------------------------------------------------
-- PARTIE B — garanties de paiement encore « actives » en mode test
-- ---------------------------------------------------------------------
-- Ces lignes portent un PaymentIntent de test. Le cron (toutes les 15 min)
-- essaierait maintenant de les capturer/annuler avec la clé live et
-- échouerait indéfiniment. On les clôt dans l'état terminal prévu par la
-- machine à états (authorization_failed), en gardant la trace au journal.
-- Aucune de ces autorisations n'a jamais retenu d'argent réel : elles
-- vivaient dans le bac à sable.
insert into public.garanties_paiement_journal (garantie_id, ancien_statut, nouveau_statut, note)
select g.id, g.statut, 'authorization_failed',
       'sql/80 — artefact sandbox cloture au passage en mode live (PI de test : '
         || coalesce(g.stripe_payment_intent_id, 'aucun') || ')'
from public.garanties_paiement g
where g.statut in ('awaiting_authorization','authorized',
                   'pending_locum_confirmation','amount_mismatch');

update public.garanties_paiement
set statut                   = 'authorization_failed',
    stripe_payment_intent_id = null,
    derniere_erreur          = 'Artefact sandbox — cloture par sql/80 lors du passage en mode live',
    updated_at               = now()
where statut in ('awaiting_authorization','authorized',
                 'pending_locum_confirmation','amount_mismatch');

-- ---------------------------------------------------------------------
-- APRÈS — vérification (doit afficher 0 partout)
-- ---------------------------------------------------------------------
select 'APRES — stripe_comptes' as etape,
       count(*)                  as lignes,
       count(stripe_customer_id) as avec_customer_doit_etre_0,
       count(stripe_account_id)  as avec_compte_doit_etre_0
from public.stripe_comptes;

select 'APRES — garanties actives (doit etre 0)' as etape,
       count(*) as lignes
from public.garanties_paiement
where statut in ('awaiting_authorization','authorized',
                 'pending_locum_confirmation','amount_mismatch');
