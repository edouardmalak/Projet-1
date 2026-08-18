-- =====================================================================
-- 85 — GARDE-FOU DE LA MACHINE À ÉTATS (au niveau de la BASE)
-- =====================================================================
-- Constat du 2026-08-18 : la machine à états des garanties n'était
-- appliquée QUE par le JavaScript du Worker. Rien, en base, n'empêchait
-- d'écrire n'importe quel statut par-dessus n'importe quel autre. Un
-- bogue dans le Worker — ou un appel service_role mal formé — pouvait
-- libérer une garantie sans que personne ne s'en aperçoive.
--
-- Ce script déplace les deux règles VITALES du skill c-direct-payments
-- dans la base, là où elles ne peuvent plus être contournées :
--
--   1. « j'ai envoyé » de la pharmacie N'ANNULE PAS la garantie.
--      C'est une affirmation NON VÉRIFIÉE : elle mène à
--      pending_locum_confirmation, jamais à confirmed_exact.
--   2. amount_mismatch N'ANNULE JAMAIS la garantie.
--      Un propriétaire qui envoie 140 $ au lieu de 1 400 $ ne doit pas
--      libérer la garantie.
--
-- Le moyen : seul le PHARMACIEN peut faire passer une garantie à
-- confirmed_exact, et il doit être nommé dans `confirme_par`. La
-- pharmacie n'a aucun chemin vers cet état, quel que soit le code appelant.
--
-- ⚠️ APRÈS CE SCRIPT : `npx wrangler deploy` est REQUIS.
--    routeConfirmerPaiement doit désormais renseigner confirme_par.
--
-- IDEMPOTENT.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) QUI a confirmé — la preuve, pas la promesse
-- ---------------------------------------------------------------------
alter table public.garanties_paiement
  add column if not exists confirme_par uuid references public.profiles(id);

comment on column public.garanties_paiement.confirme_par is
  'Pharmacien ayant confirme « recu, montant exact ». OBLIGATOIRE pour atteindre confirmed_exact, et doit etre le pharmacien de la candidature. C''est ce qui empeche la pharmacie de liberer sa propre garantie.';

-- ---------------------------------------------------------------------
-- 2) LA TABLE DES TRANSITIONS LÉGALES
--    Tout ce qui n'est pas listé ici est refusé.
-- ---------------------------------------------------------------------
create or replace function public.transition_garantie_legale(p_ancien text, p_nouveau text)
returns boolean
language sql immutable
as $$
  select case
    -- Pas de changement : toujours toléré (mise à jour d'un autre champ)
    when p_ancien is not distinct from p_nouveau then true
    -- Première écriture
    when p_ancien is null then p_nouveau = 'awaiting_authorization'
    -- Tentative d'autorisation
    when p_ancien = 'awaiting_authorization'
      then p_nouveau in ('authorized','authorization_failed')
    -- Échec : nouvelle tentative de l'échelle de relance (max 5, géré ailleurs)
    when p_ancien = 'authorization_failed'
      then p_nouveau = 'awaiting_authorization'
    -- Autorisation en place : tous les dénouements
    when p_ancien = 'authorized'
      then p_nouveau in ('pending_locum_confirmation','amount_mismatch',
                         'confirmed_exact','captured','capture_failed')
    -- La pharmacie dit avoir payé — NON VÉRIFIÉ
    when p_ancien = 'pending_locum_confirmation'
      then p_nouveau in ('amount_mismatch','confirmed_exact','captured','capture_failed')
    -- Écart de montant signalé : on peut encore capturer, ou le pharmacien
    -- peut confirmer apres correction. JAMAIS de retour en arriere.
    when p_ancien = 'amount_mismatch'
      then p_nouveau in ('confirmed_exact','captured','capture_failed')
    -- États terminaux
    when p_ancien in ('confirmed_exact','captured') then false
    when p_ancien = 'capture_failed' then p_nouveau = 'captured'  -- reprise manuelle apres correction
    else false
  end;
$$;

-- ---------------------------------------------------------------------
-- 3) LE DÉCLENCHEUR
-- ---------------------------------------------------------------------
create or replace function public.garde_machine_etats_garanties()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_pharmacien uuid;
begin
  -- a) La transition est-elle prévue par la machine à états ?
  if not public.transition_garantie_legale(
       case when TG_OP = 'INSERT' then null else old.statut end,
       new.statut) then
    raise exception
      'Transition de garantie interdite : % -> % (garantie %)',
      coalesce(old.statut,'(nouvelle)'), new.statut, new.id
      using errcode = 'check_violation';
  end if;

  -- b) RÈGLE VITALE — seul le pharmacien libère la garantie.
  --    Couvre les deux invariants du skill d'un seul coup :
  --    le « j'ai envoye » de la pharmacie ne peut pas atteindre cet etat,
  --    et amount_mismatch ne peut pas etre annule par quelqu'un d'autre.
  if new.statut = 'confirmed_exact'
     and (old.statut is distinct from 'confirmed_exact') then

    if new.confirme_par is null then
      raise exception
        'confirmed_exact exige confirme_par : seul le pharmacien peut liberer une garantie (garantie %)', new.id
        using errcode = 'check_violation';
    end if;

    select c.pharmacien_id into v_pharmacien
      from public.candidatures c
     where c.id = new.candidature_id;

    if v_pharmacien is null or new.confirme_par <> v_pharmacien then
      raise exception
        'confirme_par (%) n''est pas le pharmacien de ce mandat (%) — une pharmacie ne peut pas liberer sa propre garantie',
        new.confirme_par, v_pharmacien
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_garde_machine_etats on public.garanties_paiement;
create trigger trg_garde_machine_etats
  before insert or update of statut on public.garanties_paiement
  for each row execute function public.garde_machine_etats_garanties();

-- ---------------------------------------------------------------------
-- VÉRIFICATION RAPIDE (les tests complets sont dans sql/86)
-- ---------------------------------------------------------------------
select 'authorized -> confirmed_exact legale ?  ' ||
       public.transition_garantie_legale('authorized','confirmed_exact')::text as t1,
       'captured -> confirmed_exact legale ?    ' ||
       public.transition_garantie_legale('captured','confirmed_exact')::text as t2,
       'amount_mismatch -> authorized legale ?  ' ||
       public.transition_garantie_legale('amount_mismatch','authorized')::text as t3;
