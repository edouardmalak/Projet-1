-- =====================================================================
-- C-DIRECT · SQL 96 — MOTEUR D'AUTO-ACCEPTATION : PORTE j REBRANCHÉE
-- (refroidissement 72 h du courriel Interac)
-- À exécuter dans Supabase → SQL Editor, APRÈS sql/95.
--
-- LE PROBLÈME (constaté et vérifié le 2026-08-22)
--   La porte j de evaluer_quart_auto() (sql/70) interroge
--   `verification_interac.cooldown_jusqua`. Or sql/75 a DÉPRÉCIÉ ce
--   mécanisme : plus RIEN n'écrit dans cette table depuis. La porte lit
--   donc une table morte, ne trouve jamais rien, et **laisse passer tous
--   les quarts**. Le refroidissement de 72 h n'est pas appliqué.
--
--   Le vrai état vit dans `profiles.courriel_interac_cooldown_jusqua`,
--   écrit par confirmer_courriel_interac() (sql/47) : sur un CHANGEMENT de
--   courriel Interac (et non à la première vérification), la colonne est
--   posée à now() + 72 heures.
--
-- POURQUOI ÇA COMPTE
--   Cette porte est la protection qui empêche un compte pharmacien
--   compromis de changer son courriel Interac puis de faire
--   auto-accepter des quarts pour détourner les paiements. Un virement
--   Interac est IRRÉVERSIBLE.
--
--   Exposition actuelle : LATENTE, pas active — Interac est éteint
--   (parametres_plateforme.interac_actif = false, sql/84, vérifié en
--   production). Le trou devient réel le jour où Interac est rallumé.
--   C'est précisément pourquoi on corrige MAINTENANT : la fenêtre où
--   toucher au moteur ne peut rien casser en production.
--
-- CE QUI CHANGE, EXACTEMENT
--   La fonction fait 226 lignes et doit être remplacée en entier
--   (CREATE OR REPLACE). Le diff entre l'ancienne et la nouvelle version
--   ne porte QUE sur la condition de la porte j — les 222 autres lignes
--   sont identiques au caractère près, vérifié par diff avant écriture.
--
--       AVANT :  select 1 from public.verification_interac vi
--                 where vi.profil_id = s.pharmacien_id
--                   and vi.cooldown_jusqua is not null
--                   and vi.cooldown_jusqua > now()
--
--       APRÈS :  select 1 from public.profiles pr
--                 where pr.id = s.pharmacien_id
--                   and pr.courriel_interac_cooldown_jusqua is not null
--                   and pr.courriel_interac_cooldown_jusqua > now()
--
--   Aucune autre porte, aucun autre calcul, aucune logique de paiement,
--   aucun code Stripe touché. Le code de la porte reste 'j' et le motif
--   journalisé dans match_log reste « refroidissement Interac 72h », donc
--   l'historique et l'écran « Rejets récents » restent cohérents.
--
--   C'est exactement le correctif prescrit par le commentaire de sql/75 :
--   « repointer cette porte vers profiles.courriel_interac_cooldown avant
--   de supprimer la table ». La table verification_interac n'est PAS
--   supprimée ici — une fois cette migration passée, plus rien ne la lit,
--   et elle pourra l'être dans une passe ultérieure.
--
-- Idempotent (CREATE OR REPLACE). Annulation en fin de fichier.
-- =====================================================================

create or replace function public.evaluer_quart_auto(p_contrat uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r public.auto_accept_admin_settings%rowtype;
  k public.contrats%rowtype;
  ph public.profiles%rowtype;
  s record;
  v_premium numeric; v_tarif_final numeric;
  v_debut timestamptz; v_heures numeric;
  v_mois_1 date; v_mois_2 date;
  v_dist numeric;
  v_gate text; v_detail jsonb;
  v_nb_heure int;
  -- accumulation (le journal est APPEND-ONLY : on n'insère qu'à la fin,
  -- quand le résultat final — booked/matched/rejected — est connu)
  a_locum uuid[] := '{}'; a_gate text[] := '{}'; a_detail jsonb[] := '{}';
  a_elig uuid[] := '{}'; a_dist numeric[] := '{}';
  a_constraint uuid[] := '{}';   -- admissibles déjà journalisés 'd-constraint'
  v_winner uuid; v_booked uuid; v_i int; v_j int;
begin
  select * into r from public.auto_accept_admin_settings where id = 1;
  select * into k from public.contrats where id = p_contrat;
  if not found or k.statut <> 'ouvert' then return; end if;

  v_debut := lower(public.aa_periode_contrat(k));
  if v_debut <= now() then return; end if;   -- quart déjà commencé/passé

  select * into ph from public.profiles where id = k.pharmacie_id;

  v_premium := coalesce(r.premium_per_hour, 0);
  v_tarif_final := k.tarif_horaire + v_premium;
  v_heures := extract(epoch from (k.heure_fin - k.heure_debut)) / 3600.0;
  if v_heures <= 0 then v_heures := v_heures + 24; end if;
  v_mois_1 := date_trunc('month', k.date_contrat)::date;
  v_mois_2 := date_trunc('month',
    k.date_contrat + case when k.heure_fin <= k.heure_debut then 1 else 0 end)::date;

  for s in
    select st.*, pn.approuve, pn.role, pn.code_postal as cp, pn.logiciels
      from public.auto_accept_locum_settings st
      join public.profiles pn on pn.id = st.pharmacien_id
  loop
    v_gate := null; v_detail := null; v_dist := null;

    -- b) activé, non suspendu, compte pharmacien approuvé
    if not s.enabled then
      v_gate := 'b'; v_detail := jsonb_build_object('raison','desactive');
    elsif s.suspended_until is not null and s.suspended_until > now() then
      v_gate := 'b'; v_detail := jsonb_build_object('raison','suspendu','jusqua',s.suspended_until);
    elsif s.role <> 'pharmacien' or not coalesce(s.approuve, false) then
      v_gate := 'b'; v_detail := jsonb_build_object('raison','compte non approuve');
    end if;

    -- c) plafond horaire de réservations automatiques
    if v_gate is null then
      select count(*) into v_nb_heure from public.match_log
       where locum_id = s.pharmacien_id and result = 'booked'
         and evaluated_at > now() - interval '1 hour';
      if v_nb_heure >= r.max_auto_bookings_per_locum_per_hour then
        v_gate := 'c';
        v_detail := jsonb_build_object('reservations_derniere_heure', v_nb_heure,
                                       'max', r.max_auto_bookings_per_locum_per_hour);
        -- quart retenu pour acceptation MANUELLE — push au pharmacien,
        -- pas de SMS ; une seule fois par (quart, pharmacien)
        if not exists (select 1 from public.match_log
                        where shift_id = p_contrat and locum_id = s.pharmacien_id
                          and rejection_gate = 'c') then
          insert into public.file_notifications (profil_id, canal, payload)
          values (s.pharmacien_id, 'push', jsonb_build_object(
            'title', 'Limite atteinte — quart disponible',
            'body',  'Limite d''auto-réservations atteinte. Le quart ' || k.numero_reference ||
                     ' reste disponible en acceptation manuelle.',
            'url',   '/c/' || k.numero_reference));
        end if;
      end if;
    end if;

    -- d) horaire libre (contrats + tampon 60 min, jours indisponibles),
    --    puis jours de semaine / périodes exclus par le pharmacien
    if v_gate is null then
      v_detail := public.aa_horaire_libre(s.pharmacien_id, p_contrat);
      if v_detail is not null then
        v_gate := 'd';
      elsif s.excluded_weekdays is not null
            and extract(dow from k.date_contrat)::int = any(s.excluded_weekdays) then
        v_gate := 'd'; v_detail := jsonb_build_object('raison','jour_exclu',
          'dow', extract(dow from k.date_contrat)::int);
      elsif s.excluded_date_ranges is not null and exists (
        select 1 from unnest(s.excluded_date_ranges) g where g @> k.date_contrat) then
        v_gate := 'd'; v_detail := jsonb_build_object('raison','periode_exclue',
          'date', k.date_contrat);
      end if;
    end if;

    -- d-bis) fraîcheur du calendrier : mois du quart confirmé (les DEUX
    -- mois si le quart chevauche minuit du dernier jour du mois)
    if v_gate is null then
      if not exists (select 1 from public.locum_calendar_confirmations
                      where locum_id = s.pharmacien_id and month = v_mois_1) then
        v_gate := 'd-bis'; v_detail := jsonb_build_object('mois_non_confirme', v_mois_1);
      elsif v_mois_2 <> v_mois_1 and not exists (
              select 1 from public.locum_calendar_confirmations
               where locum_id = s.pharmacien_id and month = v_mois_2) then
        v_gate := 'd-bis'; v_detail := jsonb_build_object('mois_non_confirme', v_mois_2);
      end if;
    end if;

    -- e) distance
    if v_gate is null then
      v_dist := public.cd_distance_km(s.cp, ph.code_postal);
      if v_dist is null then
        v_gate := 'e'; v_detail := jsonb_build_object('raison','distance inconnue (code postal manquant)');
      elsif s.max_distance_km is not null and v_dist > s.max_distance_km then
        v_gate := 'e'; v_detail := jsonb_build_object('distance_km', round(v_dist), 'max', s.max_distance_km);
      end if;
    end if;

    -- f) durée du quart
    if v_gate is null and s.max_hours_per_shift is not null
       and v_heures > s.max_hours_per_shift then
      v_gate := 'f'; v_detail := jsonb_build_object('heures', v_heures, 'max', s.max_hours_per_shift);
    end if;

    -- g) (taux affiché + prime) ≥ taux minimum du pharmacien
    if v_gate is null and s.min_rate is not null and v_tarif_final < s.min_rate then
      v_gate := 'g'; v_detail := jsonb_build_object('tarif_avec_prime', v_tarif_final, 'min', s.min_rate);
    end if;

    -- h) logiciel de la pharmacie ∈ logiciels connus du pharmacien
    if v_gate is null then
      if ph.logiciel is null then
        v_gate := 'h'; v_detail := jsonb_build_object('raison','logiciel pharmacie non renseigne');
      elsif s.logiciels is null or not (ph.logiciel = any(s.logiciels)) then
        v_gate := 'h'; v_detail := jsonb_build_object('logiciel_pharmacie', ph.logiciel);
      end if;
    end if;

    -- i) intégration Stripe complète (charges_enabled && payouts_enabled)
    if v_gate is null and not exists (
      select 1 from public.stripe_comptes sc
       where sc.profil_id = s.pharmacien_id
         and coalesce((sc.stripe_account_statut->>'charges_enabled')::boolean, false)
         and coalesce((sc.stripe_account_statut->>'payouts_enabled')::boolean, false)) then
      v_gate := 'i'; v_detail := jsonb_build_object('raison','integration Stripe incomplete');
    end if;

    -- j) courriel Interac PAS dans la fenêtre de refroidissement 72 h
    if v_gate is null and exists (
      select 1 from public.profiles pr
       where pr.id = s.pharmacien_id
         and pr.courriel_interac_cooldown_jusqua is not null
         and pr.courriel_interac_cooldown_jusqua > now()) then
      v_gate := 'j'; v_detail := jsonb_build_object('raison','refroidissement Interac 72h');
    end if;

    -- k) aucun blocage/sourdine entre cette pharmacie et ce pharmacien
    if v_gate is null and (
         public.est_bloque(s.pharmacien_id, k.pharmacie_id)
         or exists (select 1 from public.locum_pharmacy_relations l
                     where l.pharmacien_id = s.pharmacien_id
                       and l.pharmacie_id = k.pharmacie_id
                       and l.state in ('muted','blocked'))
         or exists (select 1 from public.favoris_pharmaciens f
                     where f.pharmacien_id = s.pharmacien_id
                       and f.pharmacie_id = k.pharmacie_id
                       and f.state in ('muted','blocked'))) then
      v_gate := 'k'; v_detail := jsonb_build_object('raison','relation bloquee/sourdine');
    end if;

    a_locum := a_locum || s.pharmacien_id;
    a_gate  := a_gate  || v_gate;             -- null = admissible
    a_detail := a_detail || v_detail;
    if v_gate is null then
      a_elig := a_elig || s.pharmacien_id;
      a_dist := a_dist || v_dist;
    end if;
  end loop;

  -- ----- départage puis réservation (essaie le suivant si la contrainte
  --       d'exclusion se déclenche — et journalise 'd-constraint') -----
  v_booked := null;
  if array_length(a_elig, 1) is not null then
    for v_winner in
      select e.pharmacien_id
        from unnest(a_elig) with ordinality as e(pharmacien_id, ord)
        join public.auto_accept_locum_settings st on st.pharmacien_id = e.pharmacien_id
       order by public.mutuellement_favori(e.pharmacien_id, k.pharmacie_id) desc,
                st.enabled_since asc nulls last,
                random()
    loop
      select a_dist[v_j] into v_dist
        from generate_subscripts(a_elig, 1) v_j where a_elig[v_j] = v_winner;
      begin
        if public.aa_reserver_quart(p_contrat, v_winner, v_dist, v_premium, v_tarif_final) then
          v_booked := v_winner;
        end if;
        exit;   -- réservé, ou contrat plus ouvert : on arrête
      exception when exclusion_violation then
        -- signal de bogue (la porte d aurait dû l'attraper) — journalisé,
        -- puis on essaie le candidat suivant
        insert into public.match_log (shift_id, locum_id, result, rejection_gate, detail)
        values (p_contrat, v_winner, 'rejected', 'd-constraint',
                jsonb_build_object('erreur', sqlerrm));
        a_constraint := a_constraint || v_winner;
      end;
    end loop;
  end if;

  -- ----- journal (append-only : une ligne par pharmacien évalué) -----
  if array_length(a_locum, 1) is not null then
    for v_i in 1 .. array_length(a_locum, 1) loop
      -- les lignes 'd-constraint' ont déjà été insérées ci-dessus
      if a_locum[v_i] = any(a_constraint) then
        continue;
      end if;
      insert into public.match_log (shift_id, locum_id, result, rejection_gate, detail)
      values (p_contrat, a_locum[v_i],
              case when a_locum[v_i] = v_booked then 'booked'
                   when a_gate[v_i] is null then 'matched'
                   else 'rejected' end,
              a_gate[v_i], a_detail[v_i]);
    end loop;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- VÉRIFICATION
--   1) la porte ne lit plus la table morte (doit renvoyer false, puis true) :
--        select
--          pg_get_functiondef('public.evaluer_quart_auto(uuid)'::regprocedure)
--            like '%verification_interac%' as lit_encore_la_table_morte,
--          pg_get_functiondef('public.evaluer_quart_auto(uuid)'::regprocedure)
--            like '%courriel_interac_cooldown_jusqua%' as lit_la_bonne_colonne;
--
--   2) test fonctionnel, si on veut le prouver : poser un refroidissement
--      sur un locum de test, puis vérifier que match_log journalise bien
--      la porte 'j' au lieu d'auto-accepter :
--        update public.profiles
--           set courriel_interac_cooldown_jusqua = now() + interval '1 hour'
--         where id = '<uuid du locum de test>';
--        -- publier un quart correspondant, puis :
--        select result, rejection_gate, detail from public.match_log
--         order by created_at desc limit 5;
--        -- puis remettre à NULL pour ne pas laisser le locum bloqué.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- ANNULATION : réexécuter sql/70-auto-acceptation-moteur.sql, qui
-- recrée evaluer_quart_auto() dans sa version d'origine (porte j pointant
-- vers verification_interac). Attention : sql/70 recrée aussi les autres
-- fonctions du moteur — c'est sans effet si aucune n'a changé depuis.
-- ---------------------------------------------------------------------
