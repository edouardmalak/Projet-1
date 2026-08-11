-- =====================================================================
-- C-DIRECT · SQL 73 — PLAFONDS D'INDEMNITÉS APPLIQUÉS (frais réels)
-- À exécuter dans Supabase → SQL Editor, APRÈS 72-auto-acceptation-acces-job2.sql.
--
-- Les plafonds de la pharmacie (profiles.plafond_deplacement /
-- plafond_per_diem / plafond_hebergement — déplacés dans Réglages le
-- 2026-08-11) cessent d'être « informatifs » : ils limitent réellement
-- les indemnités.
--
--   · PHOTOGRAPHIE à la publication (même patron que la prime
--     d'auto-acceptation, sql/68) : les plafonds du profil sont copiés
--     sur le CONTRAT au moment de l'insert. Changer son profil ensuite
--     ne touche jamais un contrat déjà publié — le pharmacien a postulé
--     sur ce qu'il a vu.
--   · APPLICATION aux deux endroits qui calculent de l'argent, avec un
--     bloc de calcul IDENTIQUE (sinon la facture et l'autorisation carte
--     T-24h divergent → amount_mismatch garanti) :
--       - marquer_complete (sql/07)        → la facture
--       - calculer_montant_locum (sql/43)  → l'autorisation carte
--     Le plafond déplacement s'applique en plafonnant les KM FACTURABLES
--     (km_factures = min(km réels A/R, plafond $ ÷ taux/km)) — la ligne
--     de facture reste « km × taux », aucune modification du rendu ni de
--     la colonne generated `total` de factures.
--   · EXPOSITION aux pharmaciens : get_contrats_ouverts et
--     get_contrat_fiche (copies EXACTES de sql/61 — dernière version —
--     + 3 colonnes en fin de liste) pour que les estimations affichées
--     (cdEstimation) correspondent au montant réellement facturé.
--   · Plafond NULL = aucun plafond (comportement d'avant, inchangé).
--   · Contrats déjà attribués/complétés : PAS de rétroactivité (plafonds
--     NULL). Les contrats encore OUVERTS sont rétro-remplis depuis le
--     profil actuel (pré-lancement, données de test).
--
-- Aucun code Stripe touché : seuls les MONTANTS calculés changent, la
-- machine à états des garanties (sql/43) est inchangée.
-- Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Colonnes de photographie sur les contrats
-- ---------------------------------------------------------------------
alter table public.contrats
  add column if not exists plafond_deplacement numeric check (plafond_deplacement is null or plafond_deplacement >= 0);
alter table public.contrats
  add column if not exists plafond_per_diem numeric check (plafond_per_diem is null or plafond_per_diem >= 0);
alter table public.contrats
  add column if not exists plafond_hebergement numeric check (plafond_hebergement is null or plafond_hebergement >= 0);

-- ---------------------------------------------------------------------
-- 2) Photographie à la publication (BEFORE INSERT)
-- ---------------------------------------------------------------------
create or replace function public.figer_plafonds_contrat()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare p public.profiles%rowtype;
begin
  select * into p from public.profiles where id = new.pharmacie_id;
  if found then
    new.plafond_deplacement := p.plafond_deplacement;
    new.plafond_per_diem    := p.plafond_per_diem;
    new.plafond_hebergement := p.plafond_hebergement;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_figer_plafonds on public.contrats;
create trigger trg_figer_plafonds
  before insert on public.contrats
  for each row execute function public.figer_plafonds_contrat();

-- Rétro-remplissage : contrats encore OUVERTS seulement.
update public.contrats k
   set plafond_deplacement = p.plafond_deplacement,
       plafond_per_diem    = p.plafond_per_diem,
       plafond_hebergement = p.plafond_hebergement
  from public.profiles p
 where p.id = k.pharmacie_id
   and k.statut = 'ouvert';

-- ---------------------------------------------------------------------
-- 3) marquer_complete — copie de sql/07 + plafonds
--    (seul changement : v_km / v_pd / v_heb plafonnés avant l'insert)
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
  v_km numeric; v_pd numeric; v_heb numeric;
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

  -- ===== BLOC PLAFONDS — identique dans calculer_montant_locum =====
  -- km facturables : min(km réels A/R, plafond $ ÷ taux/km)
  v_km := round((coalesce(c.distance_km, 0) * 2)::numeric, 2);
  if k.plafond_deplacement is not null and coalesce(r.taux_km, 0.70) > 0 then
    v_km := least(v_km, round((k.plafond_deplacement / coalesce(r.taux_km, 0.70))::numeric, 2));
  end if;
  v_pd  := case when k.per_diem
                then least(coalesce(r.per_diem_jour, 0),
                           coalesce(k.plafond_per_diem, coalesce(r.per_diem_jour, 0)))
                else 0 end;
  v_heb := case when k.hebergement
                then least(coalesce(r.hebergement_jour, 0),
                           coalesce(k.plafond_hebergement, coalesce(r.hebergement_jour, 0)))
                else 0 end;
  -- ===== fin du bloc plafonds =====

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
     v_km,
     r.taux_km,
     v_pd,
     v_heb,
     'contrat', 'brouillon')
  returning id into v_facture;

  return v_facture;
end;
$$;
revoke all on function public.marquer_complete(uuid) from public, anon;
grant execute on function public.marquer_complete(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4) calculer_montant_locum — copie de sql/43 + le MÊME bloc plafonds
--    (dimensionne l'autorisation carte T-24h : doit égaler la facture)
-- ---------------------------------------------------------------------
create or replace function public.calculer_montant_locum(p_candidature_id uuid)
returns numeric
language plpgsql stable security definer set search_path = public
as $$
declare
  c public.candidatures%rowtype;
  k public.contrats%rowtype;
  r public.regles_reseau%rowtype;
  v_hd time; v_hf time; v_heures numeric;
  v_km numeric; v_pd numeric; v_heb numeric;
  v_total numeric;
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

  -- ===== BLOC PLAFONDS — identique dans marquer_complete =====
  v_km := round((coalesce(c.distance_km, 0) * 2)::numeric, 2);
  if k.plafond_deplacement is not null and coalesce(r.taux_km, 0.70) > 0 then
    v_km := least(v_km, round((k.plafond_deplacement / coalesce(r.taux_km, 0.70))::numeric, 2));
  end if;
  v_pd  := case when k.per_diem
                then least(coalesce(r.per_diem_jour, 0),
                           coalesce(k.plafond_per_diem, coalesce(r.per_diem_jour, 0)))
                else 0 end;
  v_heb := case when k.hebergement
                then least(coalesce(r.hebergement_jour, 0),
                           coalesce(k.plafond_hebergement, coalesce(r.hebergement_jour, 0)))
                else 0 end;
  -- ===== fin du bloc plafonds =====

  v_total := v_heures * coalesce(c.tarif_propose, k.tarif_horaire)
           + v_km * coalesce(r.taux_km, 0.70)
           + v_pd
           + v_heb;

  return round(v_total, 2);
end;
$$;
revoke all on function public.calculer_montant_locum(uuid) from public, anon;
grant execute on function public.calculer_montant_locum(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5) get_contrats_ouverts — copie EXACTE de sql/61 + 3 colonnes plafonds
--    (drop nécessaire : la forme de retour change)
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean,
  profession_recherchee text, hebergement_offerte boolean,
  rx_jour_semaine int, rx_jour_weekend int, seul_pharmacien boolean,
  atp_presente boolean, services text[], has_automation boolean,
  fiabilite_note numeric, fiabilite_nb bigint,
  acces_prioritaire_actif boolean, mutuellement_favori_actif boolean,
  plafond_deplacement numeric, plafond_per_diem numeric, plafond_hebergement numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (public.mon_role() in ('pharmacien','admin')) then
    raise exception 'Accès refusé';
  end if;
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.statut, p.ville, p.logiciel, p.code_postal,
           exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           k.profession_recherchee, k.hebergement_offerte,
           k.rx_jour_semaine, k.rx_jour_weekend, k.seul_pharmacien,
           k.atp_presente, k.services, k.has_automation,
           fp.note_moyenne, fp.nb_avis,
           (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a),
           public.mutuellement_favori(auth.uid(), k.pharmacie_id),
           k.plafond_deplacement, k.plafond_per_diem, k.plafond_hebergement
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
      left join lateral public.get_fiabilite_pharmacie(k.pharmacie_id) fp on true
     where k.statut = 'ouvert'
       and (
         public.est_admin()
         or (
           not public.est_bloque(auth.uid(), k.pharmacie_id)
           and k.profession_recherchee = coalesce(
             (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien')
           and (
             not (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a)
             or exists (select 1 from public.favoris_pharmaciens tf
                         where tf.pharmacie_id = k.pharmacie_id and tf.pharmacien_id = auth.uid() and tf.state = 'trusted')
           )
         )
       )
     order by k.created_at desc;
end;
$$;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- 6) get_contrat_fiche — copie EXACTE de sql/61 + 3 colonnes plafonds
-- ---------------------------------------------------------------------
drop function if exists public.get_contrat_fiche(text);
create or replace function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text, code_postal text,
  ma_candidature_statut text, est_ma_pharmacie boolean,
  profession_recherchee text,
  hebergement_offerte boolean, hebergement_adresse text,
  pharmacie_nom text, pharmacie_note_moyenne numeric, pharmacie_note_nombre bigint,
  pharmacien_nom text, pharmacien_note_moyenne numeric, pharmacien_note_nombre bigint,
  pharmacien_favoris_nombre bigint,
  has_automation boolean, lunch_coverage boolean,
  fiabilite_note numeric, fiabilite_nb bigint,
  acces_prioritaire_actif boolean, mutuellement_favori_actif boolean,
  plafond_deplacement numeric, plafond_per_diem numeric, plafond_hebergement numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    with base as (
      select k.*, p.ville as p_ville, p.logiciel as p_logiciel, p.code_postal as p_code_postal,
             p.nom_pharmacie as p_nom_pharmacie,
             p.hebergement_adresse as p_hebergement_adresse,
             (select c.statut from public.candidatures c
               where c.contrat_id = k.id and c.pharmacien_id = auth.uid()) as ma_candidature_statut,
             (k.pharmacie_id = auth.uid()) as est_ma_pharmacie,
             (
               k.statut in ('attribue','complete')
               and (
                 k.pharmacie_id = auth.uid()
                 or public.est_admin()
                 or exists(select 1 from public.candidatures ca
                           where ca.contrat_id = k.id and ca.pharmacien_id = auth.uid()
                             and ca.statut = 'accepte')
               )
             ) as reveler,
             (select ca.pharmacien_id from public.candidatures ca
               where ca.contrat_id = k.id and ca.statut = 'accepte' limit 1) as v_pharmacien_id,
             fp.note_moyenne as fp_note_moyenne, fp.nb_avis as fp_nb_avis
        from public.contrats k
        join public.profiles p on p.id = k.pharmacie_id
        left join lateral public.get_fiabilite_pharmacie(k.pharmacie_id) fp on true
       where k.numero_reference = upper(trim(p_ref))
         and (
           public.est_admin()
           or k.pharmacie_id = auth.uid()
           or (public.mon_role() = 'pharmacien'
               and (
                 (k.statut = 'ouvert'
                  and k.profession_recherchee = coalesce(
                    (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien')
                  and (
                    not (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a)
                    or exists (select 1 from public.favoris_pharmaciens tf
                                where tf.pharmacie_id = k.pharmacie_id and tf.pharmacien_id = auth.uid() and tf.state = 'trusted')
                  ))
                 or public.a_postule(k.id)
               )
               and not public.est_bloque(auth.uid(), k.pharmacie_id))
         )
    )
    select b.id, b.numero_reference, b.date_contrat,
           b.heure_debut, b.heure_fin, b.tarif_horaire,
           b.rx_jour_semaine, b.rx_jour_weekend,
           b.seul_pharmacien, b.atp_presente, b.services,
           b.notes, b.statut, b.created_at,
           b.p_ville, b.p_logiciel, b.p_code_postal,
           b.ma_candidature_statut, b.est_ma_pharmacie,
           b.profession_recherchee,
           b.hebergement_offerte,
           case when b.reveler and b.hebergement_offerte then b.p_hebergement_adresse else null end,
           case when b.reveler
             then coalesce(nullif(b.p_nom_pharmacie,''), b.p_ville, 'Pharmacie')
             else null end,
           case when b.reveler
             then (select np.moyenne from public.get_note_profil(b.pharmacie_id) np)
             else null end,
           case when b.reveler
             then (select np.nombre from public.get_note_profil(b.pharmacie_id) np)
             else null end,
           case when b.reveler and b.v_pharmacien_id is not null then (
             select coalesce(nullif(trim(coalesce(pn.prenom,'')||' '||coalesce(pn.nom,'')),''), pn.courriel, 'Pharmacien(ne)')
               from public.profiles pn where pn.id = b.v_pharmacien_id
           ) else null end,
           case when b.reveler and b.v_pharmacien_id is not null
             then (select np.moyenne from public.get_note_profil(b.v_pharmacien_id) np)
             else null end,
           case when b.reveler and b.v_pharmacien_id is not null
             then (select np.nombre from public.get_note_profil(b.v_pharmacien_id) np)
             else null end,
           case when b.reveler and b.v_pharmacien_id is not null
             then (select count(*) from public.favoris_pharmaciens fp2 where fp2.pharmacien_id = b.v_pharmacien_id and fp2.state = 'trusted')
             else null end,
           b.has_automation, b.lunch_coverage,
           b.fp_note_moyenne, b.fp_nb_avis,
           (b.acces_prioritaire and b.acces_prioritaire_jusqu_a is not null and now() < b.acces_prioritaire_jusqu_a),
           public.mutuellement_favori(auth.uid(), b.pharmacie_id),
           b.plafond_deplacement, b.plafond_per_diem, b.plafond_hebergement
      from base b;
end;
$$;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   select column_name from information_schema.columns
--    where table_name='contrats' and column_name like 'plafond%';   -- 3 lignes
--   select tgname from pg_trigger where tgname='trg_figer_plafonds'; -- 1 ligne
--   select proname from pg_proc where proname in
--    ('marquer_complete','calculer_montant_locum','get_contrats_ouverts','get_contrat_fiche');
-- =====================================================================
