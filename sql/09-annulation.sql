-- =====================================================================
-- C-DIRECT · PHASE 3 · SQL 09 — PROTECTION D'ANNULATION
-- À exécuter APRÈS 08-envoi-paiement-pgcron.sql, dans Supabase → SQL Editor.
--
-- Règles du réseau :
--   · Pharmacie qui annule un contrat ATTRIBUÉ :
--       < 7 jours avant le début → pénalité penalite_annulation_7j_pct %
--       < 48 h avant le début   → pénalité penalite_annulation_48h_pct %
--       (base : heures convenues × tarif convenu — payable au pharmacien)
--     Facture type 'penalite_annulation' générée AUTOMATIQUEMENT,
--     statut 'envoyee' immédiatement. Aucune pénalité hors fenêtres
--     ni pour un contrat encore 'ouvert'.
--   · Pharmacien qui annule : contrat remis 'ouvert', candidature
--     'refuse', journalisé (visibilité admin) — aucune facture.
-- =====================================================================

-- ---------------------------------------------------------------------
-- RPC · annuler_contrat_pharmacie
-- Renvoie jsonb : { penalite_pct, facture_id } (facture_id null si 0 %).
-- ---------------------------------------------------------------------
create or replace function public.annuler_contrat_pharmacie(p_contrat uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  k public.contrats%rowtype;
  c public.candidatures%rowtype;
  r public.regles_reseau%rowtype;
  v_hd time; v_hf time;
  v_debut timestamptz;
  v_heures_avant numeric;
  v_heures numeric;
  v_pct int := 0;
  v_facture uuid;
begin
  select * into k from public.contrats
   where id = p_contrat
     and (pharmacie_id = auth.uid() or public.est_admin())
   for update;
  if not found then raise exception 'Contrat introuvable ou accès refusé'; end if;
  if k.statut not in ('ouvert','attribue') then
    raise exception 'Ce contrat ne peut plus être annulé (statut : %)', k.statut;
  end if;

  -- contrat encore ouvert : annulation simple, aucune pénalité
  if k.statut = 'ouvert' then
    update public.contrats set statut = 'annule' where id = p_contrat;
    return jsonb_build_object('penalite_pct', 0, 'facture_id', null);
  end if;

  -- contrat attribué : protection du pharmacien
  select * into c from public.candidatures
   where contrat_id = p_contrat and statut = 'accepte'
   order by updated_at desc limit 1;
  if not found then raise exception 'Candidature acceptée introuvable'; end if;

  select * into r from public.regles_reseau where id = 1;

  v_hd := coalesce(c.heure_debut_proposee, k.heure_debut);
  v_hf := coalesce(c.heure_fin_proposee,  k.heure_fin);
  v_debut := (k.date_contrat + v_hd) at time zone 'America/Toronto';
  v_heures_avant := extract(epoch from (v_debut - now())) / 3600.0;

  if v_heures_avant < 48 then
    v_pct := r.penalite_annulation_48h_pct;      -- < 48 h (inclut contrat déjà commencé)
  elsif v_heures_avant < 24 * 7 then
    v_pct := r.penalite_annulation_7j_pct;       -- < 7 jours
  else
    v_pct := 0;                                  -- hors fenêtres : aucune pénalité
  end if;

  update public.contrats set statut = 'annule' where id = p_contrat;

  -- journal (visibilité admin) — 'auto' : aucun courriel parasite
  update public.candidatures
     set message = public.ajouter_jalon(message, jsonb_build_object(
       'etape','annule','par','pharmacie','penalite_pct',v_pct,'auto',true))
   where id = c.id;

  if v_pct > 0 then
    v_heures := extract(epoch from (v_hf - v_hd)) / 3600.0;
    if v_heures < 0 then v_heures := v_heures + 24; end if;

    -- pénalité = pct % de (heures × tarif) → heures facturées au prorata
    insert into public.factures
      (candidature_id, heures, tarif_horaire, km, taux_km,
       per_diem_montant, hebergement_montant, type_facture, statut,
       date_envoi, date_echeance)
    values
      (c.id,
       round((v_heures * v_pct / 100.0)::numeric, 2),
       coalesce(c.tarif_propose, k.tarif_horaire),
       0, 0, 0, 0,
       'penalite_annulation', 'envoyee',
       now(), current_date + coalesce(r.delai_paiement_jours, 30))
    returning id into v_facture;
  end if;

  return jsonb_build_object('penalite_pct', v_pct, 'facture_id', v_facture);
end;
$$;
revoke all on function public.annuler_contrat_pharmacie(uuid) from public, anon;
grant execute on function public.annuler_contrat_pharmacie(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- RPC · annuler_contrat_pharmacien — le pharmacien retenu se désiste :
-- contrat remis 'ouvert', candidature 'refuse' (jalon 'annule' journalisé,
-- 'auto' pour éviter le courriel « non retenue » trompeur), indemnités
-- remises à zéro. Aucune facture.
-- ---------------------------------------------------------------------
create or replace function public.annuler_contrat_pharmacien(p_contrat uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare c public.candidatures%rowtype;
begin
  select c2.* into c
    from public.candidatures c2
    join public.contrats k on k.id = c2.contrat_id
   where c2.contrat_id = p_contrat
     and (c2.pharmacien_id = auth.uid() or public.est_admin())
     and c2.statut = 'accepte'
     and k.statut = 'attribue';
  if not found then
    raise exception 'Remplacement introuvable ou déjà clos';
  end if;

  update public.candidatures
     set statut = 'refuse',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','annule','par','pharmacien','auto',true))
   where id = c.id;

  update public.contrats
     set statut = 'ouvert', per_diem = false, hebergement = false
   where id = p_contrat;
end;
$$;
revoke all on function public.annuler_contrat_pharmacien(uuid) from public, anon;
grant execute on function public.annuler_contrat_pharmacien(uuid) to authenticated;
