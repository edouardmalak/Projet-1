-- =====================================================================
-- C-DIRECT · PHASE 3 · SQL 07 — COMPLÉTION → FACTURE
-- À exécuter APRÈS 06-notifications-email.sql, dans Supabase → SQL Editor.
-- Le schéma est FIGÉ : aucune table modifiée — uniquement des RPC
-- security definer (la RLS de factures n'autorise l'écriture qu'à
-- l'admin ; ces fonctions sont la seule porte d'écriture contrôlée).
-- =====================================================================

-- ---------------------------------------------------------------------
-- RPC · marquer_complete — l'une OU l'autre des parties marque le
-- contrat complété (statut 'attribue' + date passée). Journalise QUI
-- a déclenché (jalon dans candidatures.message), puis génère la
-- facture 'brouillon' à partir de la candidature acceptée :
--   heures  = durée de l'horaire convenu
--   tarif   = tarif convenu
--   km      = distance_km × 2 (aller-retour) au taux regles_reseau
--   per diem / hébergement = montants regles_reseau si le contrat y
--   donne droit (drapeaux posés par appliquer_indemnites à l'entente).
-- Idempotent : si la facture existe déjà, la renvoie sans dupliquer.
-- ---------------------------------------------------------------------
create or replace function public.marquer_complete(p_contrat uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  k public.contrats%rowtype;
  c public.candidatures%rowtype;
  r public.regles_reseau%rowtype;
  v_par text;
  v_hd time; v_hf time;
  v_heures numeric;
  v_facture uuid;
begin
  select * into k from public.contrats where id = p_contrat for update;
  if not found then raise exception 'Contrat introuvable'; end if;

  select * into c from public.candidatures
   where contrat_id = p_contrat and statut = 'accepte'
   order by updated_at desc limit 1;
  if not found then raise exception 'Aucune candidature acceptée pour ce contrat'; end if;

  -- qui déclenche ? (journalisé)
  if k.pharmacie_id = auth.uid() then v_par := 'pharmacie';
  elsif c.pharmacien_id = auth.uid() then v_par := 'pharmacien';
  elsif public.est_admin() then v_par := 'admin';
  else raise exception 'Accès refusé';
  end if;

  if k.statut <> 'attribue' then
    raise exception 'Seul un contrat attribué peut être marqué complété (statut actuel : %)', k.statut;
  end if;
  if k.date_contrat > current_date then
    raise exception 'La date du contrat (%) n''est pas encore passée', k.date_contrat;
  end if;

  select * into r from public.regles_reseau where id = 1;

  -- horaire convenu (contre-offre acceptée > horaire affiché)
  v_hd := coalesce(c.heure_debut_proposee, k.heure_debut);
  v_hf := coalesce(c.heure_fin_proposee,  k.heure_fin);
  v_heures := extract(epoch from (v_hf - v_hd)) / 3600.0;
  if v_heures < 0 then v_heures := v_heures + 24; end if;
  v_heures := round(v_heures::numeric, 2);

  update public.contrats set statut = 'complete' where id = p_contrat;

  -- journal : qui a marqué complété ('auto' → aucun courriel parasite)
  update public.candidatures
     set message = public.ajouter_jalon(message, jsonb_build_object(
       'etape','complete','par',v_par,'auto',true))
   where id = c.id;

  -- idempotence
  select id into v_facture from public.factures
   where candidature_id = c.id and type_facture = 'contrat';
  if found then return v_facture; end if;

  insert into public.factures
    (candidature_id, heures, tarif_horaire, km, taux_km,
     per_diem_montant, hebergement_montant, type_facture, statut)
  values
    (c.id,
     v_heures,
     coalesce(c.tarif_propose, k.tarif_horaire),
     coalesce(c.distance_km, 0) * 2,                    -- aller-retour
     r.taux_km,
     case when k.per_diem    then r.per_diem_jour    else 0 end,
     case when k.hebergement then r.hebergement_jour else 0 end,
     'contrat', 'brouillon')
  returning id into v_facture;

  return v_facture;
end;
$$;
revoke all on function public.marquer_complete(uuid) from public, anon;
grant execute on function public.marquer_complete(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- RPC · get_factures — les factures de l'utilisateur courant avec tout
-- le contexte du MANDAT (parties, contrat). Admin : toutes.
-- (RPC nécessaire : la RLS de profiles ne laisse pas une partie lire
-- le profil de l'autre — on expose ici UNIQUEMENT les champs du MANDAT.)
-- ---------------------------------------------------------------------
create or replace function public.get_factures()
returns table (
  facture_id uuid, numero_facture int, type_facture text, statut text,
  heures numeric, tarif_horaire numeric, km numeric, taux_km numeric,
  per_diem_montant numeric, hebergement_montant numeric, total numeric,
  date_envoi timestamptz, date_paiement timestamptz, date_echeance date,
  cree_le timestamptz,
  candidature_id uuid, contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time,
  pharmacien_id uuid, pharmacien_prenom text, pharmacien_nom text,
  pharmacien_opq text, pharmacien_courriel text,
  pharmacie_id uuid, nom_pharmacie text, pharmacie_adresse text,
  pharmacie_ville text, pharmacie_cp text, pharmacie_neq text, pharmacie_courriel text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select f.id, f.numero_facture, f.type_facture, f.statut,
           f.heures, f.tarif_horaire, f.km, f.taux_km,
           f.per_diem_montant, f.hebergement_montant, f.total,
           f.date_envoi, f.date_paiement, f.date_echeance,
           f.created_at,
           c.id, k.id, k.numero_reference, k.date_contrat,
           coalesce(c.heure_debut_proposee, k.heure_debut),
           coalesce(c.heure_fin_proposee,  k.heure_fin),
           pn.id, pn.prenom, pn.nom, pn.numero_opq, pn.courriel,
           pe.id, pe.nom_pharmacie, pe.adresse, pe.ville, pe.code_postal, pe.neq, pe.courriel
      from public.factures f
      join public.candidatures c on c.id = f.candidature_id
      join public.contrats k     on k.id = c.contrat_id
      join public.profiles pn    on pn.id = c.pharmacien_id
      join public.profiles pe    on pe.id = k.pharmacie_id
     where public.est_admin()
        or c.pharmacien_id = auth.uid()
        or k.pharmacie_id = auth.uid()
     order by f.created_at desc;
end;
$$;
revoke all on function public.get_factures() from public, anon;
grant execute on function public.get_factures() to authenticated;

-- ---------------------------------------------------------------------
-- RPC · get_mes_mandats — les contrats du pharmacien connecté dont la
-- candidature a été ACCEPTÉE (attribués, complétés, annulés), avec le
-- nom de la pharmacie (invisible via la RLS de profiles).
-- ---------------------------------------------------------------------
create or replace function public.get_mes_mandats()
returns table (
  contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif numeric, statut text,
  candidature_id uuid, nom_pharmacie text, ville text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           coalesce(c.heure_debut_proposee, k.heure_debut),
           coalesce(c.heure_fin_proposee,  k.heure_fin),
           coalesce(c.tarif_propose, k.tarif_horaire),
           k.statut, c.id, pe.nom_pharmacie, pe.ville
      from public.candidatures c
      join public.contrats k  on k.id = c.contrat_id
      join public.profiles pe on pe.id = k.pharmacie_id
     where c.pharmacien_id = auth.uid()
       and c.statut = 'accepte'
     order by k.date_contrat desc;
end;
$$;
revoke all on function public.get_mes_mandats() from public, anon;
grant execute on function public.get_mes_mandats() to authenticated;

-- ---------------------------------------------------------------------
-- RPC · ajuster_km_facture — le pharmacien révise le brouillon : si le
-- trajet réel diffère, il ajuste les km (TOTAL aller-retour). Brouillon
-- de type 'contrat' seulement.
-- ---------------------------------------------------------------------
create or replace function public.ajuster_km_facture(p_facture uuid, p_km numeric)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if p_km is null or p_km < 0 or p_km > 5000 then
    raise exception 'Kilométrage invalide';
  end if;
  update public.factures f
     set km = round(p_km::numeric, 1)
    from public.candidatures c
   where f.id = p_facture
     and c.id = f.candidature_id
     and f.statut = 'brouillon'
     and f.type_facture = 'contrat'
     and (c.pharmacien_id = auth.uid() or public.est_admin());
  if not found then
    raise exception 'Facture introuvable ou non modifiable (brouillon seulement)';
  end if;
end;
$$;
revoke all on function public.ajuster_km_facture(uuid, numeric) from public, anon;
grant execute on function public.ajuster_km_facture(uuid, numeric) to authenticated;
