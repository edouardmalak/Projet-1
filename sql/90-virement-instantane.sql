-- =====================================================================
-- 90 — VIREMENT INSTANTANÉ AU PHARMACIEN (traces)
-- =====================================================================
-- Décision de Robert, 2026-08-18 : « attendre n'est pas une option, chaque
-- paiement doit être instantané, et le pharmacien n'absorbe jamais de
-- frais ». Le 1 % de Stripe est donc payé par la plateforme.
--
-- Réglage tableau de bord fait le 2026-08-18 18:43 :
--   Connect → Payouts → External accounts → « Allow debit cards? » = Oui.
--
-- ---------------------------------------------------------------------
-- CE QUE LA DOC STRIPE IMPOSE (lu, pas deviné)
-- docs.stripe.com/connect/instant-payouts :
--   • Au CANADA, le virement instantané n'est possible que vers une CARTE
--     DE DÉBIT. Les comptes bancaires ne sont PAS admissibles ici,
--     contrairement aux États-Unis, au Royaume-Uni, à l'UE, etc.
--   • `instant_available.net_available` n'apparaît QUE pour les comptes
--     externes réellement admissibles. Un pharmacien sans carte de débit
--     n'y figure tout simplement pas : c'est notre test d'admissibilité,
--     offert par l'API elle-même.
--   • Minimum 0,60 $ CA, maximum 9 999 $ CA par virement.
--   • Stripe facture 1 % à la PLATEFORME sur chaque virement instantané.
--   • Un nouveau compte connecté n'est PAS admissible immédiatement :
--     Stripe applique une montée en charge selon le volume traité et l'âge
--     du compte, et chaque plateforme a un plafond quotidien.
--
-- Conséquence de conception : le virement instantané est TENTÉ après
-- chaque capture, et son échec n'est JAMAIS une erreur de paiement. Si
-- l'instantané n'est pas possible, Stripe versera de toute façon selon le
-- calendrier normal. On enregistre ce qui s'est passé, on n'échoue pas.
-- =====================================================================

alter table public.garanties_paiement
  add column if not exists payout_id text,
  add column if not exists payout_methode text
    check (payout_methode is null or payout_methode in ('instant','standard')),
  add column if not exists payout_montant_cents int,
  add column if not exists payout_erreur text,
  add column if not exists payout_le timestamptz;

comment on column public.garanties_paiement.payout_methode is
  'instant = verse en ~30 min sur la carte de debit du pharmacien. standard = Stripe versera au calendrier normal (l''instantane n''etait pas possible). Un echec ici n''est PAS un echec de paiement.';

-- Cache d'admissibilité, pour prévenir le pharmacien AVANT le quart
-- plutôt que de le découvrir au moment de le payer.
alter table public.stripe_comptes
  add column if not exists paiement_instantane_pret boolean,
  add column if not exists paiement_instantane_verifie_le timestamptz;

comment on column public.stripe_comptes.paiement_instantane_pret is
  'null = jamais verifie. false = aucune carte de debit admissible (au Canada, un compte bancaire ne suffit PAS pour l''instantane). Sert a avertir le pharmacien avant qu''il accepte un quart.';

-- ---------------------------------------------------------------------
-- Lecture pour l'écran du pharmacien (et, plus tard, l'app)
-- ---------------------------------------------------------------------
create or replace function public.mon_paiement_instantane()
returns table (pret boolean, verifie_le timestamptz)
language sql stable security definer set search_path = public
as $$
  select sc.paiement_instantane_pret, sc.paiement_instantane_verifie_le
    from public.stripe_comptes sc
   where sc.profil_id = auth.uid();
$$;
revoke all on function public.mon_paiement_instantane() from public, anon;
grant execute on function public.mon_paiement_instantane() to authenticated;

select 'colonnes de versement ajoutees' as etape,
       (select count(*) from information_schema.columns
         where table_schema='public' and table_name='garanties_paiement'
           and column_name like 'payout%') as colonnes_garanties,
       (select count(*) from information_schema.columns
         where table_schema='public' and table_name='stripe_comptes'
           and column_name like 'paiement_instantane%') as colonnes_comptes;
