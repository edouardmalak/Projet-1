-- =====================================================================
-- C-DIRECT · PAIEMENTS STRIPE · SQL 43 — GARANTIE DE PAIEMENT (état)
-- À exécuter APRÈS sql/42-fondations-paiements.sql, dans Supabase → SQL Editor.
--
-- Ce fichier ne fait AUCUN appel Stripe. Il pose la machine à états qui
-- suit la garantie de paiement de chaque mandat confirmé (candidature
-- acceptée) :
--
--   awaiting_authorization → authorized → pending_locum_confirmation
--     → confirmed_exact (annulée, 0 $)      [le pharmacien confirme reçu + montant exact]
--     → amount_mismatch (PAS annulée)        [le pharmacien signale un écart — jamais d'annulation auto]
--     → captured (deadline dépassée)         [carte débitée, le pharmacien est payé via Connect]
--   authorization_failed                     [échec de création — ex. pharmacien pas encore onboardé]
--
-- Toutes les écritures Stripe (création/annulation/capture) vivent dans le
-- Worker c-direct-payments (service_role, jamais le client). Ici : lecture
-- seule pour les deux parties, plus une RPC read-only pour calculer le
-- montant dû au pharmacien (même formule que marquer_complete, AVANT que
-- le contrat soit complété — nécessaire puisque l'autorisation se crée à
-- T-24h, avant le quart).
-- =====================================================================

-- ---------------------------------------------------------------------
-- stripe_comptes.stripe_payment_method_id — l'ID de la carte PLATEFORME
-- de la pharmacie (nécessaire pour la CLONER vers le compte connecté du
-- pharmacien à chaque quart — sql/42 n'avait stocké que le customer_id).
-- ---------------------------------------------------------------------
alter table public.stripe_comptes
  add column if not exists stripe_payment_method_id text;

-- ---------------------------------------------------------------------
-- RPC · calculer_montant_locum — même calcul que marquer_complete
-- (sql/07), mais en LECTURE SEULE, utilisable avant que le contrat soit
-- complété. Sert à savoir combien autoriser sur la carte à T-24h.
-- ---------------------------------------------------------------------
create or replace function public.calculer_montant_locum(p_candidature_id uuid)
returns numeric
language plpgsql stable security definer set search_path = public
as $$
declare
  c public.candidatures%rowtype;
  k public.contrats%rowtype;
  r public.regles_reseau%rowtype;
  v_hd time; v_hf time; v_heures numeric; v_total numeric;
begin
  select * into c from public.candidatures where id = p_candidature_id;
  if not found then raise exception 'Candidature introuvable'; end if;
  select * into k from public.contrats where id = c.contrat_id;
  if not found then raise exception 'Contrat introuvable'; end if;
  select * into r from public.regles_reseau where id = 1;

  v_hd := coalesce(c.heure_debut_proposee, k.heure_debut);
  v_hf := coalesce(c.heure_fin_proposee,  k.heure_fin);
  v_heures := extract(epoch from (v_hf - v_hd)) / 3600.0;
  if v_heures < 0 then v_heures := v_heures + 24; end if;
  v_heures := round(v_heures::numeric, 2);

  v_total := v_heures * coalesce(c.tarif_propose, k.tarif_horaire)
           + coalesce(c.distance_km, 0) * 2 * coalesce(r.taux_km, 0.70)
           + case when k.per_diem    then coalesce(r.per_diem_jour, 0)    else 0 end
           + case when k.hebergement then coalesce(r.hebergement_jour, 0) else 0 end;

  return round(v_total, 2);
end;
$$;
revoke all on function public.calculer_montant_locum(uuid) from public, anon;
grant execute on function public.calculer_montant_locum(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- TABLE · garanties_paiement — une ligne par candidature acceptée pour
-- laquelle une garantie carte a été (ou doit être) créée.
-- ---------------------------------------------------------------------
create table if not exists public.garanties_paiement (
  id uuid primary key default gen_random_uuid(),
  candidature_id uuid not null unique references public.candidatures(id) on delete cascade,
  statut text not null default 'awaiting_authorization' check (statut in (
    'awaiting_authorization', 'authorized', 'pending_locum_confirmation',
    'confirmed_exact', 'amount_mismatch', 'captured', 'authorization_failed'
  )),
  stripe_payment_intent_id text,
  montant_locum_cents int not null,        -- net dû au pharmacien (calculer_montant_locum × 100)
  montant_carte_cents int,                 -- montant carte réellement autorisé (rempli après succès)
  capture_before timestamptz,              -- plafond DUR Stripe (payment_method_details.card.capture_before) — ne jamais capturer/retenter après
  echeance_confirmation timestamptz,       -- délai souple : 3h après envoi de facture (rempli à l'envoi)
  tentative_autorisation int not null default 0,
  derniere_erreur text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_garanties_paiement_statut on public.garanties_paiement(statut);

alter table public.garanties_paiement enable row level security;

drop policy if exists "garanties_paiement_select_parties" on public.garanties_paiement;
create policy "garanties_paiement_select_parties" on public.garanties_paiement
  for select using (
    exists (
      select 1 from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      where c.id = garanties_paiement.candidature_id
        and (c.pharmacien_id = auth.uid() or k.pharmacie_id = auth.uid())
    )
    or public.est_admin()
  );
-- Volontairement AUCUNE politique insert/update/delete pour authenticated/anon :
-- toute écriture vient du Worker (service_role) après un appel Stripe réel,
-- jamais directement du client — même logique que stripe_comptes (sql/42).

-- ---------------------------------------------------------------------
-- TABLE · garanties_paiement_journal — journal des transitions, horodaté.
-- C'est la preuve en cas de litige carte (skill : « that log is the
-- evidence record in a card dispute »).
-- ---------------------------------------------------------------------
create table if not exists public.garanties_paiement_journal (
  id uuid primary key default gen_random_uuid(),
  garantie_id uuid not null references public.garanties_paiement(id) on delete cascade,
  ancien_statut text,
  nouveau_statut text not null,
  note text,
  created_at timestamptz not null default now()
);

alter table public.garanties_paiement_journal enable row level security;

drop policy if exists "garanties_paiement_journal_select_parties" on public.garanties_paiement_journal;
create policy "garanties_paiement_journal_select_parties" on public.garanties_paiement_journal
  for select using (
    exists (
      select 1 from public.garanties_paiement g
      join public.candidatures c on c.id = g.candidature_id
      join public.contrats k on k.id = c.contrat_id
      where g.id = garanties_paiement_journal.garantie_id
        and (c.pharmacien_id = auth.uid() or k.pharmacie_id = auth.uid())
    )
    or public.est_admin()
  );

-- ---------------------------------------------------------------------
-- get_mes_mandats — RECRÉÉE (forme de retour changée) pour inclure le
-- statut de la garantie de paiement, afin que mes-mandats.html affiche
-- « Garantie active / Payé / Écart signalé » et les boutons de
-- confirmation du pharmacien.
-- ---------------------------------------------------------------------
drop function if exists public.get_mes_mandats();
create or replace function public.get_mes_mandats()
returns table (
  contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif numeric, statut text,
  candidature_id uuid, nom_pharmacie text, ville text,
  statut_garantie text, montant_carte numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           coalesce(c.heure_debut_proposee, k.heure_debut),
           coalesce(c.heure_fin_proposee,  k.heure_fin),
           coalesce(c.tarif_propose, k.tarif_horaire),
           k.statut, c.id, pe.nom_pharmacie, pe.ville,
           g.statut, round(g.montant_carte_cents / 100.0, 2)
      from public.candidatures c
      join public.contrats k  on k.id = c.contrat_id
      join public.profiles pe on pe.id = k.pharmacie_id
      left join public.garanties_paiement g on g.candidature_id = c.id
     where c.pharmacien_id = auth.uid()
       and c.statut = 'accepte'
     order by k.date_contrat desc;
end;
$$;
revoke all on function public.get_mes_mandats() from public, anon;
grant execute on function public.get_mes_mandats() to authenticated;

-- ---------------------------------------------------------------------
-- Les trois RPC ci-dessous sont appelées UNIQUEMENT par le Worker
-- c-direct-payments (clé service_role) — jamais par le client. Elles
-- traversent les candidatures/contrats de TOUT LE MONDE, donc aucun
-- grant à authenticated (seul service_role — qui contourne ces grants
-- de toute façon — doit pouvoir les exécuter).
-- ---------------------------------------------------------------------

-- RPC · lister_candidatures_a_autoriser — candidatures acceptées dont le
-- quart démarre dans moins de p_fenetre_heures et qui n'ont pas encore
-- de garantie. Ne remonte PAS les quarts déjà commencés (T-24h ratée =
-- cas à traiter par la relance, hors périmètre de cette passe — voir
-- PLAN-APP-MOBILE / tâche #19 pour la suite).
create or replace function public.lister_candidatures_a_autoriser(p_fenetre_heures int default 24)
returns table (
  candidature_id uuid, pharmacien_id uuid, pharmacie_id uuid,
  montant_locum numeric, debut_quart timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select c.id, c.pharmacien_id, k.pharmacie_id,
           public.calculer_montant_locum(c.id),
           (k.date_contrat + coalesce(c.heure_debut_proposee, k.heure_debut))::timestamptz
      from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
     where c.statut = 'accepte'
       and k.statut = 'attribue'
       and (k.date_contrat + coalesce(c.heure_debut_proposee, k.heure_debut))::timestamptz
             between now() and now() + make_interval(hours => p_fenetre_heures)
       and not exists (select 1 from public.garanties_paiement g where g.candidature_id = c.id);
end;
$$;
revoke all on function public.lister_candidatures_a_autoriser(int) from public, anon, authenticated;

-- RPC · lister_echeances_a_fixer — garanties autorisées dont la facture
-- vient d'être ENVOYÉE (equivalent « soumission du relevé d'heures » —
-- voir marquer_complete/envoyer_facture, sql/07-08) mais qui n'ont pas
-- encore de délai de confirmation calculé.
create or replace function public.lister_echeances_a_fixer()
returns table (garantie_id uuid, date_envoi timestamptz)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select g.id, f.date_envoi
      from public.garanties_paiement g
      join public.candidatures c on c.id = g.candidature_id
      join public.factures f on f.candidature_id = c.id and f.type_facture = 'contrat'
     where g.statut = 'authorized'
       and g.echeance_confirmation is null
       and f.date_envoi is not null;
end;
$$;
revoke all on function public.lister_echeances_a_fixer() from public, anon, authenticated;

-- RPC · lister_garanties_a_capturer — garanties dont le délai de
-- confirmation (3h après envoi facture) est dépassé, OU dont le plafond
-- Stripe (capture_before) approche (garde-fou : ne jamais laisser une
-- autorisation expirer faute de facture envoyée — skill : « never let a
-- ladder push a capture past the charge's capture_before »).
create or replace function public.lister_garanties_a_capturer()
returns table (garantie_id uuid, stripe_payment_intent_id text, pharmacien_id uuid)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select g.id, g.stripe_payment_intent_id, c.pharmacien_id
      from public.garanties_paiement g
      join public.candidatures c on c.id = g.candidature_id
     where g.statut in ('authorized', 'pending_locum_confirmation', 'amount_mismatch')
       and (
         (g.echeance_confirmation is not null and g.echeance_confirmation <= now())
         or (g.capture_before is not null and g.capture_before <= now() + interval '6 hours')
       );
end;
$$;
revoke all on function public.lister_garanties_a_capturer() from public, anon, authenticated;

-- Vérification : select statut, count(*) from public.garanties_paiement group by statut;
