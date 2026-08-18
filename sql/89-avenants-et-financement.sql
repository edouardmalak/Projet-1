-- =====================================================================
-- 89 — AVENANTS D'HEURES ET DÉCLENCHEMENT DU FINANCEMENT
-- =====================================================================
-- Décisions de Robert, 2026-08-18 :
--   • Le DÉPART déclenche le financement.
--   • Une BAISSE d'heures se finance immédiatement — elle est en faveur
--     de la pharmacie, son accord n'apporte rien.
--   • Une HAUSSE demande son accord. Silence pendant 3 h → on prélève le
--     montant DU CONTRAT et l'écart devient une réclamation distincte.
--     Personne n'est jamais débité au-delà de ce qu'il a accepté.
--   • Départ oublié → pointage automatique à la fin prévue + 2 h.
--
-- ---------------------------------------------------------------------
-- CONTRAINTE STRIPE VÉRIFIÉE DANS LA DOC (pas de mémoire)
-- https://docs.stripe.com/api/payment_intents/capture :
--   « amount_to_capture ... must be less than or equal to the original
--     amount »
-- On peut donc capturer MOINS que l'autorisation, jamais plus. Une hausse
-- d'heures ne peut PAS être financée par la garantie existante : Stripe
-- refuse d'augmenter une autorisation déjà posée. La hausse approuvée est
-- donc enregistrée comme un supplément à régler à part, et la garantie
-- couvre au maximum ce qui avait été autorisé. C'est une limite du rail,
-- pas un choix de conception.
--
-- La même doc précise que `application_fee_amount` peut être redonné à la
-- capture. C'est indispensable : sans ça, une capture partielle garderait
-- les frais calculés sur le gros montant et le pharmacien recevrait moins
-- que son dû.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Ce qu'il faut RÉELLEMENT capturer (null = tout ce qui a été autorisé)
-- ---------------------------------------------------------------------
alter table public.garanties_paiement
  add column if not exists montant_final_cents int,
  add column if not exists montant_locum_final_cents int,
  add column if not exists supplement_du_cents int not null default 0;

comment on column public.garanties_paiement.montant_final_cents is
  'Montant carte a capturer reellement, apres pointage. null = capturer toute l''autorisation.';
comment on column public.garanties_paiement.supplement_du_cents is
  'Heures supplementaires approuvees mais NON couvertes par la garantie : Stripe interdit d''augmenter une autorisation posee. A regler separement.';

-- ---------------------------------------------------------------------
-- 2) Le prix carte, en SQL — MÊME formule que calculerMontantCarte()
--    du Worker. card = (locum + frais + 0.30) / (1 - 0.029)
-- ---------------------------------------------------------------------
create or replace function public.cd_montant_carte_cents(p_montant_locum numeric)
returns int
language sql stable security definer set search_path = public
as $$
  select round(
    ((p_montant_locum + coalesce(public.frais_plateforme(), 39) + 0.30) / (1 - 0.029)) * 100
  )::int;
$$;

-- ---------------------------------------------------------------------
-- 3) LES AVENANTS — une hausse d'heures proposée, à approuver
-- ---------------------------------------------------------------------
create table if not exists public.avenants (
  id uuid primary key default gen_random_uuid(),
  candidature_id uuid not null unique references public.candidatures(id) on delete cascade,
  heures_contrat numeric not null,
  heures_pointees numeric not null,
  ecart_minutes int not null,
  montant_locum_contrat numeric not null,
  montant_locum_pointe numeric not null,
  statut text not null default 'en_attente'
    check (statut in ('en_attente','approuve','expire')),
  echeance timestamptz not null,
  approuve_par uuid references public.profiles(id),
  approuve_le timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_avenants_echeance on public.avenants(statut, echeance);

alter table public.avenants enable row level security;
drop policy if exists avenants_select on public.avenants;
create policy avenants_select on public.avenants
  for select using (
    exists (select 1 from public.candidatures c
            join public.contrats k on k.id = c.contrat_id
            where c.id = avenants.candidature_id
              and (c.pharmacien_id = auth.uid() or k.pharmacie_id = auth.uid() or public.est_admin()))
  );

-- ---------------------------------------------------------------------
-- 4) FINALISER — appelé au départ. Décide : financer, ou demander l'accord.
-- ---------------------------------------------------------------------
create or replace function public.finaliser_pointage(p_candidature uuid)
returns table (suite text, montant_locum numeric, echeance timestamptz)
language plpgsql volatile security definer set search_path = public
as $$
declare
  c public.candidatures%rowtype; k public.contrats%rowtype;
  g public.garanties_paiement%rowtype;
  v_arr timestamptz; v_dep timestamptz;
  v_hp numeric; v_hc numeric; v_ecart int;
  v_taux numeric; v_lc numeric; v_lp numeric;
  v_suite text; v_ech timestamptz;
begin
  select * into c from public.candidatures where id = p_candidature;
  if not found then raise exception 'Mandat introuvable'; end if;
  select * into k from public.contrats where id = c.contrat_id;
  select * into g from public.garanties_paiement where candidature_id = p_candidature;

  select moment into v_arr from public.pointages where candidature_id=p_candidature and type='arrivee';
  select moment into v_dep from public.pointages where candidature_id=p_candidature and type='depart';
  if v_arr is null or v_dep is null then
    return query select 'pointage_incomplet'::text, null::numeric, null::timestamptz; return;
  end if;

  v_hp := round((extract(epoch from (v_dep - v_arr)) / 3600.0)::numeric, 2);
  v_hc := round((
    extract(epoch from (coalesce(c.heure_fin_proposee,k.heure_fin) - coalesce(c.heure_debut_proposee,k.heure_debut)))/3600.0
    + case when coalesce(c.heure_fin_proposee,k.heure_fin) <= coalesce(c.heure_debut_proposee,k.heure_debut) then 24 else 0 end
  )::numeric, 2);
  v_ecart := round((v_hp - v_hc) * 60)::int;

  v_taux := coalesce(c.tarif_propose, k.tarif_horaire);
  v_lc := round(v_hc * v_taux, 2);   -- du au contrat
  v_lp := round(v_hp * v_taux, 2);   -- du selon le pointage

  if g.id is null then
    return query select 'aucune_garantie'::text, v_lp, null::timestamptz; return;
  end if;

  if v_ecart <= 0 then
    -- BAISSE (ou pile) : on finance tout de suite, en capturant MOINS.
    update public.garanties_paiement
       set montant_locum_final_cents = round(v_lp * 100)::int,
           montant_final_cents = public.cd_montant_carte_cents(v_lp),
           echeance_confirmation = now()     -- rend la garantie capturable au prochain cycle
     where id = g.id;
    v_suite := 'financer_maintenant';
  else
    -- HAUSSE : l'accord de la pharmacie est requis, 3 h de delai.
    v_ech := now() + interval '3 hours';
    insert into public.avenants (candidature_id, heures_contrat, heures_pointees, ecart_minutes,
                                 montant_locum_contrat, montant_locum_pointe, echeance)
    values (p_candidature, v_hc, v_hp, v_ecart, v_lc, v_lp, v_ech)
    on conflict (candidature_id) do update
      set heures_pointees = excluded.heures_pointees,
          ecart_minutes = excluded.ecart_minutes,
          montant_locum_pointe = excluded.montant_locum_pointe,
          echeance = excluded.echeance,
          statut = 'en_attente'
    returning avenants.echeance into v_ech;
    v_suite := 'approbation_pharmacie_requise';
  end if;

  return query select v_suite, case when v_ecart <= 0 then v_lp else v_lc end, v_ech;
end;
$$;
revoke all on function public.finaliser_pointage(uuid) from public, anon;
grant execute on function public.finaliser_pointage(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5) LA PHARMACIE APPROUVE la hausse
-- ---------------------------------------------------------------------
create or replace function public.approuver_avenant(p_candidature uuid)
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare
  a public.avenants%rowtype; g public.garanties_paiement%rowtype;
  v_pharmacie uuid; v_autorise int; v_voulu int;
begin
  select * into a from public.avenants where candidature_id = p_candidature;
  if not found then raise exception 'Aucun avenant pour ce mandat'; end if;
  if a.statut <> 'en_attente' then return a.statut; end if;

  select k.pharmacie_id into v_pharmacie
    from public.candidatures c join public.contrats k on k.id = c.contrat_id
   where c.id = p_candidature;
  if v_pharmacie <> auth.uid() and not public.est_admin() then
    raise exception 'Seule la pharmacie de ce mandat peut approuver';
  end if;

  select * into g from public.garanties_paiement where candidature_id = p_candidature;

  -- Stripe interdit d'augmenter une autorisation deja posee. On capture au
  -- maximum ce qui avait ete autorise ; le reste devient un supplement du.
  v_voulu := public.cd_montant_carte_cents(a.montant_locum_pointe);
  v_autorise := coalesce(g.montant_carte_cents, v_voulu);

  update public.garanties_paiement
     set montant_locum_final_cents = round(a.montant_locum_pointe * 100)::int,
         montant_final_cents = least(v_voulu, v_autorise),
         supplement_du_cents = greatest(v_voulu - v_autorise, 0),
         echeance_confirmation = now()
   where id = g.id;

  update public.avenants
     set statut = 'approuve', approuve_par = auth.uid(), approuve_le = now()
   where id = a.id;

  return 'approuve';
end;
$$;
revoke all on function public.approuver_avenant(uuid) from public, anon;
grant execute on function public.approuver_avenant(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6) LE CRON — avenants expirés : on paie le montant DU CONTRAT
-- ---------------------------------------------------------------------
create or replace function public.traiter_avenants_expires()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare v_n int := 0; r record;
begin
  for r in
    select a.id, a.candidature_id, a.montant_locum_contrat
      from public.avenants a
     where a.statut = 'en_attente' and a.echeance <= now()
     for update skip locked
  loop
    update public.garanties_paiement g
       set montant_locum_final_cents = round(r.montant_locum_contrat * 100)::int,
           montant_final_cents = public.cd_montant_carte_cents(r.montant_locum_contrat),
           echeance_confirmation = now()
     where g.candidature_id = r.candidature_id;
    update public.avenants set statut = 'expire' where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.traiter_avenants_expires() from public, anon, authenticated;
grant execute on function public.traiter_avenants_expires() to service_role;

-- ---------------------------------------------------------------------
-- 7) LE CRON — départs oubliés : pointage automatique à fin prévue + 2 h
-- ---------------------------------------------------------------------
create or replace function public.pointer_departs_oublies()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare v_n int := 0; r record; v_fin timestamptz;
begin
  for r in
    select c.id as candidature_id, k.date_contrat,
           coalesce(c.heure_debut_proposee,k.heure_debut) as hd,
           coalesce(c.heure_fin_proposee,k.heure_fin) as hf
      from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      join public.pointages a on a.candidature_id = c.id and a.type = 'arrivee'
      left join public.pointages d on d.candidature_id = c.id and d.type = 'depart'
     where c.statut = 'accepte' and d.id is null
     for update of c skip locked
  loop
    v_fin := ((r.date_contrat + case when r.hf <= r.hd then 1 else 0 end)::timestamp + r.hf)
             at time zone 'America/Toronto';
    if v_fin + interval '2 hours' <= now() then
      insert into public.pointages (candidature_id, type, moment, automatique)
      values (r.candidature_id, 'depart', v_fin, true)
      on conflict (candidature_id, type) do nothing;
      perform public.finaliser_pointage(r.candidature_id);
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.pointer_departs_oublies() from public, anon, authenticated;
grant execute on function public.pointer_departs_oublies() to service_role;

select 'avenants' as table_creee,
       (select count(*) from public.avenants) as lignes,
       public.cd_montant_carte_cents(1360) as exemple_carte_cents_pour_1360;
