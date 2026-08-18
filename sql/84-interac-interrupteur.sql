-- =====================================================================
-- 84 — INTERRUPTEUR INTERAC (éteint par défaut)
-- =====================================================================
-- Décision de Robert, 2026-08-18 : Interac est retiré comme moyen de
-- règlement pour les premiers mois. La pharmacie paie par carte (crédit
-- OU débit — les deux circulent sur les réseaux de cartes et passent déjà
-- par le rail Stripe existant). Le chèque reste possible sur entente entre
-- les deux parties, sans être affiché à la réservation ; le pharmacien
-- confirme alors « reçu, montant exact » et l'autorisation est annulée.
--
-- CE SCRIPT NE TOUCHE QUE LA PLOMBERIE. Les textes de vente du site
-- public (index.html, faq.html, regles.html, pharmacies.html,
-- profil.html) parlent encore d'Interac : ils seront réécrits en une
-- seule passe, avec le repositionnement « paiement garanti et instantané ».
-- Tant que cette réécriture n'est pas faite, le site VEND Interac alors
-- que l'application ne l'offre plus. C'est voulu et temporaire.
--
-- IDEMPOTENT.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) LE RÉGLAGE — sur la même ligne unique que les frais (sql/82)
-- ---------------------------------------------------------------------
alter table public.parametres_plateforme
  add column if not exists interac_actif boolean not null default false;

comment on column public.parametres_plateforme.interac_actif is
  'false = Interac n''est plus proposé comme moyen de règlement. La carte devient le seul rail affiché ; le chèque reste possible hors écran, avec confirmation du pharmacien.';

-- ---------------------------------------------------------------------
-- 2) HISTORIQUE — le déclencheur de sql/82 ne suivait que les frais.
--    On le remplace pour qu'il journalise aussi ce nouveau champ.
-- ---------------------------------------------------------------------
create or replace function public.journaliser_parametres_plateforme()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.frais_cdirect_dollars is distinct from old.frais_cdirect_dollars then
    insert into public.parametres_plateforme_history
      (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'frais_cdirect_dollars',
            old.frais_cdirect_dollars::text, new.frais_cdirect_dollars::text);
  end if;
  if new.interac_actif is distinct from old.interac_actif then
    insert into public.parametres_plateforme_history
      (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'interac_actif',
            old.interac_actif::text, new.interac_actif::text);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) ÉCRITURE — admin seulement, jamais en direct sur la table
-- ---------------------------------------------------------------------
create or replace function public.modifier_interac_actif(p_actif boolean)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_nouveau boolean;
begin
  if not public.est_admin() then
    raise exception 'Accès refusé';
  end if;
  if p_actif is null then
    raise exception 'Valeur requise (true ou false).';
  end if;

  update public.parametres_plateforme
     set interac_actif = p_actif
   where id = 1
  returning interac_actif into v_nouveau;

  return v_nouveau;
end;
$$;
revoke all on function public.modifier_interac_actif(boolean) from public, anon;
grant execute on function public.modifier_interac_actif(boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 4) LECTURE — une seule fonction pour les deux réglages dont le
--    site a besoin. Ni l'un ni l'autre n'est un secret : les frais
--    s'affichent au prix, et l'état d'Interac décide de ce qu'on montre.
--    La table elle-même reste fermée (RLS admin uniquement).
-- ---------------------------------------------------------------------
create or replace function public.reglages_paiement()
returns table (frais_cdirect_dollars numeric, interac_actif boolean)
language sql stable security definer set search_path = public
as $$
  select p.frais_cdirect_dollars, p.interac_actif
    from public.parametres_plateforme p
   where p.id = 1;
$$;
revoke all on function public.reglages_paiement() from public;
grant execute on function public.reglages_paiement() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- VÉRIFICATION
-- ---------------------------------------------------------------------
select 'reglages en vigueur' as etape, * from public.reglages_paiement();
