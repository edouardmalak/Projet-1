-- =====================================================================
-- C-DIRECT · SQL 70 — AUTO-ACCEPTATION (JOB 1/2) · MOTEUR SÉQUENCEUR UNIQUE
-- À exécuter APRÈS 69-auto-acceptation-file-et-journal.sql.
--
-- UN SEUL moteur, planifié par pg_cron (SQL 71, toutes les 30 s) :
--   1. pg_try_advisory_lock — si le verrou n'est pas obtenu, une autre
--      exécution est en cours : on sort immédiatement. Garantit UNE SEULE
--      instance du moteur, toujours. Verrou relâché en toute circonstance
--      (bloc exception = « finally ») ; un plantage de session le relâche
--      aussi automatiquement (verrou de session Postgres).
--   2. matching_paused ou feature OFF → sortie sans traiter (la file
--      s'accumule et se vide à la reprise).
--   3. lignes 'pending' traitées en ordre d'id, strictement en série.
-- Les courses de réservation sont impossibles PAR CONSTRUCTION ; le
-- FOR UPDATE sur le contrat pendant la réservation est conservé quand
-- même (défense en profondeur), et la contrainte d'exclusion (SQL 68)
-- reste le filet ultime au niveau base.
--
-- PAIEMENTS — AUCUN code Stripe ici : la candidature acceptée est prise
-- en charge par le flux T-24h EXISTANT (Worker c-direct-payments, cron
-- 15 min, lister_candidatures_a_autoriser à fenêtre 24 h). Un quart
-- réservé à MOINS de 24 h du début entre dans la fenêtre dès la
-- prochaine passe du Worker (≤ 15 min). La prime circule par
-- candidatures.tarif_propose = tarif affiché + prime → montant du
-- pharmacien, autorisation carte (formule dual-pricing existante) et
-- facture (UNE ligne au taux horaire majoré) suivent sans modification.
-- Les frais C-Direct restent 39 $ fixes.
--
-- Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Petits outils
-- ---------------------------------------------------------------------

-- SMS sans accents (règle du repo : GSM-7, jamais d'Unicode).
create or replace function public.aa_sans_accents(p text)
returns text
language sql immutable
as $$
  select translate(coalesce(p, ''),
    'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ’',
    'aaaeeeeiioouuucAAAEEEEIIOOUUUC''');
$$;

-- Début / fin réels d'un contrat (fuseau America/Toronto, quart de nuit
-- = fin le lendemain).
create or replace function public.aa_periode_contrat(k public.contrats)
returns tstzrange
language sql stable
as $$
  select tstzrange(
    (k.date_contrat::timestamp + k.heure_debut) at time zone 'America/Toronto',
    ((k.date_contrat + case when k.heure_fin <= k.heure_debut then 1 else 0 end)::timestamp
      + k.heure_fin) at time zone 'America/Toronto',
    '[)');
$$;

-- ---------------------------------------------------------------------
-- 1) PORTE d — horaire libre ?  null = libre, sinon jsonb {raison…}.
--    · aucun contrat accepté qui chevauche, AVEC tampon de déplacement :
--      minimum 60 min entre deux quarts de pharmacies DIFFÉRENTES
--      (0 min si même pharmacie) ;
--    · aucune journée marquée INDISPONIBLE sur les dates du quart.
--    Ré-exécutée telle quelle DANS la transaction de réservation.
-- ---------------------------------------------------------------------
create or replace function public.aa_horaire_libre(p_pharmacien uuid, p_contrat uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare k public.contrats%rowtype; v_p tstzrange; v_ref text; v_jour date;
begin
  select * into k from public.contrats where id = p_contrat;
  if not found then return jsonb_build_object('raison', 'contrat introuvable'); end if;
  v_p := public.aa_periode_contrat(k);

  -- contrat accepté qui chevauche (tampon 60 min si autre pharmacie)
  select k2.numero_reference into v_ref
    from public.candidatures c2
    join public.contrats k2 on k2.id = c2.contrat_id
   where c2.pharmacien_id = p_pharmacien
     and c2.statut = 'accepte'
     and c2.periode is not null
     and k2.statut <> 'annule'
     and c2.periode && tstzrange(
           lower(v_p) - case when k2.pharmacie_id = k.pharmacie_id
                             then interval '0' else interval '60 minutes' end,
           upper(v_p) + case when k2.pharmacie_id = k.pharmacie_id
                             then interval '0' else interval '60 minutes' end,
           '[)')
   limit 1;
  if v_ref is not null then
    return jsonb_build_object('raison', 'conflit_contrat', 'contrat', v_ref);
  end if;

  -- journée(s) indisponible(s)
  for v_jour in
    select d::date from generate_series(
      k.date_contrat,
      k.date_contrat + case when k.heure_fin <= k.heure_debut then 1 else 0 end,
      interval '1 day') d
  loop
    if exists (select 1 from public.disponibilites d
                where d.pharmacien_id = p_pharmacien
                  and d.date_dispo = v_jour and d.statut = 'indisponible') then
      return jsonb_build_object('raison', 'jour_indisponible', 'date', v_jour);
    end if;
  end loop;

  return null;
end;
$$;

-- ---------------------------------------------------------------------
-- 2) RÉSERVATION ATOMIQUE (appelée par le séquenceur uniquement)
--    FOR UPDATE sur le contrat, RE-vérification de l'horaire DANS la
--    transaction, jalon, refus des autres candidatures, photographie de
--    la prime, indemnités, notifications. La contrainte d'exclusion
--    (SQL 68) peut encore lever 23P01 — capté par l'appelant et
--    journalisé 'd-constraint'.
-- ---------------------------------------------------------------------
create or replace function public.aa_reserver_quart(
  p_contrat uuid, p_pharmacien uuid, p_distance numeric,
  p_premium numeric, p_tarif_final numeric)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  k public.contrats%rowtype;
  v_cand uuid; v_tel text; v_optin boolean; v_courriel_ph text;
  v_ville text; v_nom_pn text;
begin
  select * into k from public.contrats where id = p_contrat for update;
  if not found or k.statut <> 'ouvert' then return false; end if;
  if public.aa_horaire_libre(p_pharmacien, p_contrat) is not null then return false; end if;

  -- candidature acceptée (ou récupération d'une candidature existante du
  -- même pharmacien sur ce contrat — unique(contrat_id, pharmacien_id))
  insert into public.candidatures
    (contrat_id, pharmacien_id, statut, tarif_propose, distance_km,
     type_candidature, message)
  values
    (p_contrat, p_pharmacien, 'accepte', p_tarif_final, p_distance,
     'auto_acceptation',
     public.ajouter_jalon(null, jsonb_build_object('etape','accepte','par','auto_acceptation')))
  on conflict (contrat_id, pharmacien_id) do update
     set statut = 'accepte',
         tarif_propose = excluded.tarif_propose,
         type_candidature = 'auto_acceptation',
         message = public.ajouter_jalon(public.candidatures.message,
           jsonb_build_object('etape','accepte','par','auto_acceptation'))
  returning id into v_cand;

  -- refus automatique des autres candidatures en attente (leur SMS
  -- « attribué à un autre » part par le webhook existant)
  update public.candidatures
     set statut = 'refuse',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','refuse','par','pharmacie','auto',true))
   where contrat_id = p_contrat and id <> v_cand
     and statut in ('propose','contre_offre');

  update public.contrats
     set statut = 'attribue',
         filled_via_auto_accept = true,
         premium_applied_per_hour = p_premium
   where id = p_contrat;

  perform public.appliquer_indemnites(p_contrat, p_distance, v_cand);

  -- ----- notifications -----
  select p.telephone, p.sms_optin into v_tel, v_optin
    from public.profiles p where p.id = p_pharmacien;
  select p.courriel, p.ville into v_courriel_ph, v_ville
    from public.profiles p where p.id = k.pharmacie_id;
  select trim(coalesce(p.prenom,'') || ' ' || coalesce(p.nom,'')) into v_nom_pn
    from public.profiles p where p.id = p_pharmacien;

  -- pharmacien : SMS immédiat (sans accents) + push
  if v_tel is not null and coalesce(v_optin, false) then
    insert into public.sms_queue (profile_id, contrat_id, pharmacie_id, to_number, type, corps, ville)
    values (p_pharmacien, p_contrat, k.pharmacie_id, v_tel, 'auto_accept_confirme',
      'C-Direct: Quart ' || k.numero_reference || ' du ' ||
      to_char(k.date_contrat, 'DD/MM') || ' a ' ||
      public.aa_sans_accents(coalesce(v_ville, 'la pharmacie')) || ', ' ||
      to_char(k.heure_debut, 'HH24hMI') || '-' || to_char(k.heure_fin, 'HH24hMI') ||
      ', reserve automatiquement pour vous a ' || round(p_tarif_final) ||
      '$/h. Details: c-direct.ca/c/' || k.numero_reference,
      v_ville);
  end if;
  insert into public.file_notifications (profil_id, canal, payload)
  values (p_pharmacien, 'push', jsonb_build_object(
    'title', 'Quart auto-accepté ✓',
    'body',  k.numero_reference || ' · ' || to_char(k.date_contrat, 'DD/MM') || ' · ' ||
             to_char(k.heure_debut, 'HH24hMI') || '-' || to_char(k.heure_fin, 'HH24hMI') ||
             ' · ' || round(p_tarif_final) || ' $/h à ' || coalesce(v_ville, 'la pharmacie'),
    'url',   '/c/' || k.numero_reference));

  -- pharmacie : push + courriel (taux final AVEC prime affiché)
  insert into public.file_notifications (profil_id, canal, payload)
  values (k.pharmacie_id, 'push', jsonb_build_object(
    'title', 'Votre quart a été comblé instantanément',
    'body',  k.numero_reference || ' · ' || to_char(k.date_contrat, 'DD/MM') || ' · ' ||
             coalesce(v_nom_pn, 'un pharmacien') || ' · ' || round(p_tarif_final) || ' $/h',
    'url',   '/c/' || k.numero_reference));
  if v_courriel_ph is not null then
    insert into public.file_notifications (profil_id, canal, payload)
    values (k.pharmacie_id, 'courriel', jsonb_build_object(
      'to',      v_courriel_ph,
      'subject', 'Votre quart ' || k.numero_reference || ' a été comblé instantanément',
      'html',
        '<p>Bonjour,</p><p>Votre quart <strong>' || k.numero_reference ||
        '</strong> du ' || to_char(k.date_contrat, 'DD/MM/YYYY') || ' (' ||
        to_char(k.heure_debut, 'HH24hMI') || '–' || to_char(k.heure_fin, 'HH24hMI') ||
        ') a été comblé instantanément par <strong>' || coalesce(v_nom_pn, 'un pharmacien') ||
        '</strong> au taux final de <strong>' || round(p_tarif_final) ||
        ' $/h</strong> (prime de remplissage instantané incluse).</p>' ||
        '<p>Détails : <a href="https://c-direct.ca/c/' || k.numero_reference ||
        '">c-direct.ca/c/' || k.numero_reference || '</a></p><p>— C-Direct</p>',
      'text',
        'Votre quart ' || k.numero_reference || ' du ' || to_char(k.date_contrat, 'DD/MM/YYYY') ||
        ' a ete comble instantanement par ' || public.aa_sans_accents(coalesce(v_nom_pn, 'un pharmacien')) ||
        ' au taux final de ' || round(p_tarif_final) || ' $/h (prime incluse). ' ||
        'Details: https://c-direct.ca/c/' || k.numero_reference));
  end if;

  return true;
end;
$$;
revoke all on function public.aa_reserver_quart(uuid, uuid, numeric, numeric, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) ÉVALUATION D'UN QUART — toutes les portes, dans l'ordre, pour CHAQUE
--    pharmacien inscrit à l'auto-acceptation ; une ligne match_log par
--    pharmacien évalué (échecs inclus). Puis départage et réservation.
--    Départage : 1) favori MUTUEL pharmacie↔pharmacien
--                2) PRIORITÉ D'ANCIENNETÉ : enabled_since le plus ancien
--                3) hasard
-- ---------------------------------------------------------------------
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
      select 1 from public.verification_interac vi
       where vi.profil_id = s.pharmacien_id
         and vi.cooldown_jusqua is not null and vi.cooldown_jusqua > now()) then
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
revoke all on function public.evaluer_quart_auto(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4) LE SÉQUENCEUR — appelé par pg_cron toutes les 30 s (SQL 71).
-- ---------------------------------------------------------------------
create or replace function public.traiter_file_matching()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  r public.auto_accept_admin_settings%rowtype;
  q record; kk record;
begin
  -- UNE SEULE instance, toujours : verrou consultatif (918273645 = clé
  -- réservée au moteur C-Direct). Pas obtenu → une exécution est en
  -- cours → sortie immédiate. (pg_try_advisory_lock, PAS pg_advisory_lock.)
  if not pg_try_advisory_lock(918273645) then return; end if;

  begin
    select * into r from public.auto_accept_admin_settings where id = 1;

    -- porte a (niveau plateforme) : bouton d'urgence ou fonction éteinte
    -- → on sort SANS traiter ; la file s'accumule et se videra ensuite.
    if not found or r.matching_paused or not r.feature_enabled then
      perform pg_advisory_unlock(918273645);
      return;
    end if;

    for q in
      select * from public.matching_queue
       where status = 'pending' order by id limit 100
    loop
      begin
        if q.event_type = 'shift_posted' then
          perform public.evaluer_quart_auto((q.payload->>'contrat_id')::uuid);
        elsif q.event_type in ('locum_settings_changed','schedule_freed') then
          -- ré-évalue les quarts ouverts à venir (l'évaluation complète
          -- par quart garantit le même départage pour tous)
          for kk in
            select k.id from public.contrats k
             where k.statut = 'ouvert' and k.date_contrat >= current_date
             order by k.date_contrat, k.heure_debut
          loop
            perform public.evaluer_quart_auto(kk.id);
          end loop;
        end if;
        -- shift_cancelled : rien à évaluer ici (le schedule_freed jumelé
        -- s'occupe du pharmacien libéré)

        update public.matching_queue
           set status = 'processed', processed_at = now() where id = q.id;
      exception when others then
        update public.matching_queue
           set status = 'failed', processed_at = now(), erreur = sqlerrm
         where id = q.id;
      end;
    end loop;
  exception when others then
    perform pg_advisory_unlock(918273645);   -- « finally » : jamais sans relâche
    raise;
  end;

  perform pg_advisory_unlock(918273645);
end;
$$;
revoke all on function public.traiter_file_matching() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5) RAPPEL MENSUEL (autour du 25) — un seul rappel, pas une série :
--    push aux pharmaciens à auto-acceptation active qui n'ont pas encore
--    confirmé le mois SUIVANT.
-- ---------------------------------------------------------------------
create or replace function public.aa_rappel_calendrier()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_mois date := date_trunc('month', current_date + interval '1 month')::date;
        v_nom text; s record;
begin
  v_nom := (array['janvier','février','mars','avril','mai','juin','juillet',
                  'août','septembre','octobre','novembre','décembre'])
           [extract(month from v_mois)::int] || ' ' || extract(year from v_mois)::int;
  for s in
    select st.pharmacien_id from public.auto_accept_locum_settings st
     where st.enabled
       and not exists (select 1 from public.locum_calendar_confirmations c
                        where c.locum_id = st.pharmacien_id and c.month = v_mois)
  loop
    insert into public.file_notifications (profil_id, canal, payload)
    values (s.pharmacien_id, 'push', jsonb_build_object(
      'title', 'Confirmez vos disponibilités',
      'body',  'Confirmez vos disponibilités pour ' || v_nom ||
               ' pour garder l''auto-acceptation active.',
      'url',   '/disponibilites.html'));
  end loop;
end;
$$;
revoke all on function public.aa_rappel_calendrier() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   select public.traiter_file_matching();   -- ne fait rien (feature OFF), ne plante pas
--   select pg_get_functiondef('public.traiter_file_matching()'::regprocedure);
--     -> doit contenir « pg_try_advisory_lock » et deux « pg_advisory_unlock »
-- =====================================================================
