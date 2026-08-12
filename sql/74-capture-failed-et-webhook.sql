-- =====================================================================
-- 74 — T8 (batch1) : état capture_failed + dédoublonnage webhook Stripe
-- ---------------------------------------------------------------------
-- (1) garanties_paiement gagne l'état terminal 'capture_failed' : une
--     capture qui échoue (carte refusée, autorisation expirée) sortait
--     du radar — le Worker journalisait puis la RPC lister_garanties_a_
--     capturer resélectionnait la ligne toutes les 15 min, en silence,
--     pour toujours. Avec un statut distinct, la ligne sort de la file
--     (la RPC ne liste que authorized / pending_locum_confirmation /
--     amount_mismatch — inchangée) et devient visible comme cas à
--     traiter à la main. Le Worker alerte pharmacie (SMS) + admin
--     (courriel) au moment du basculement.
-- (2) stripe_evenements : table de dédoublonnage des webhooks Stripe
--     (event.id est unique ; Stripe peut livrer un évènement deux fois).
--     Service-role seulement — RLS activée sans policy.
-- =====================================================================

-- (1) élargir la contrainte de statut
alter table public.garanties_paiement
  drop constraint if exists garanties_paiement_statut_check;
alter table public.garanties_paiement
  add constraint garanties_paiement_statut_check check (statut in (
    'awaiting_authorization', 'authorized', 'pending_locum_confirmation',
    'confirmed_exact', 'amount_mismatch', 'captured', 'authorization_failed',
    'capture_failed'
  ));

-- (2) journal des évènements webhook reçus (idempotence)
create table if not exists public.stripe_evenements (
  id text primary key,              -- event.id Stripe (evt_…)
  type text not null,
  compte text,                      -- event.account (acct_…) pour les webhooks Connect
  recu_le timestamptz not null default now()
);

alter table public.stripe_evenements enable row level security;
-- Aucune policy : lecture/écriture réservées au service_role (Worker).

-- Vérification :
--   select statut, count(*) from public.garanties_paiement group by statut;
--   select count(*) from public.stripe_evenements;
