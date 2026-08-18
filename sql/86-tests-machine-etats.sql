-- =====================================================================
-- 86 — TESTS DE LA MACHINE À ÉTATS DES GARANTIES
-- =====================================================================
-- Suite d'assertions exécutable À TOUT MOMENT dans l'éditeur SQL de
-- Supabase. Aucune dépendance, aucun outil à installer (le dépôt n'a ni
-- gestionnaire de paquets ni étape de compilation — voir CLAUDE.md).
--
-- NON DESTRUCTIF : tout se déroule dans une transaction terminée par
-- ROLLBACK. Les données de test créées ici n'existent plus à la fin.
-- On peut donc la relancer en production sans rien salir.
--
-- Elle vérifie les deux règles qui, si elles cassent, coûtent de l'argent
-- réel à quelqu'un :
--   T4 — « j'ai envoyé » de la pharmacie n'annule PAS la garantie
--   T5 — amount_mismatch n'annule JAMAIS la garantie
--
-- Usage : coller, exécuter, lire la dernière colonne. Tout doit dire OK.
-- =====================================================================

begin;

do $$
declare
  v_pharmacie   uuid;
  v_pharmacien  uuid;
  v_autre       uuid;
  v_contrat     uuid;
  v_candidature uuid;
  v_garantie    uuid;
  v_echecs      int := 0;
  v_ok          int := 0;
begin
  -- ---------------------------------------------------------------
  -- Décor : on réutilise de vrais profils existants pour respecter
  -- les clés étrangères, sans jamais les modifier.
  -- ---------------------------------------------------------------
  select id into v_pharmacie  from public.profiles where role = 'pharmacie'  limit 1;
  select id into v_pharmacien from public.profiles where role = 'pharmacien' limit 1;
  select id into v_autre      from public.profiles where role = 'pharmacie'
    and id <> v_pharmacie limit 1;
  if v_autre is null then v_autre := v_pharmacie; end if;

  if v_pharmacie is null or v_pharmacien is null then
    raise exception 'TESTS IMPOSSIBLES : il faut au moins un profil pharmacie et un profil pharmacien.';
  end if;

  insert into public.contrats (pharmacie_id, date_contrat, heure_debut, heure_fin,
                               tarif_horaire, statut, notes)
  values (v_pharmacie, current_date + 1, '09:00', '17:00', 200, 'attribue',
          'TEST AUTOMATISE sql/86 — annule par ROLLBACK')
  returning id into v_contrat;

  insert into public.candidatures (contrat_id, pharmacien_id, statut, tarif_propose, distance_km)
  values (v_contrat, v_pharmacien, 'accepte', 200, 0)
  returning id into v_candidature;

  -- =================================================================
  -- T1 — une garantie naît forcément en awaiting_authorization
  -- =================================================================
  begin
    insert into public.garanties_paiement (candidature_id, statut, montant_locum_cents)
    values (v_candidature, 'captured', 160000);
    raise exception 'T1_ECHEC';
  exception
    when check_violation then v_ok := v_ok + 1;
      raise notice 'T1 OK  — naissance directe en « captured » refusee';
    when others then
      if sqlerrm = 'T1_ECHEC' then
        v_echecs := v_echecs + 1;
        raise notice 'T1 ECHEC — une garantie a pu naitre en « captured » !';
      else raise; end if;
  end;

  insert into public.garanties_paiement (candidature_id, statut, montant_locum_cents)
  values (v_candidature, 'awaiting_authorization', 160000)
  returning id into v_garantie;
  v_ok := v_ok + 1;
  raise notice 'T2 OK  — naissance en « awaiting_authorization » acceptee';

  update public.garanties_paiement set statut = 'authorized' where id = v_garantie;
  v_ok := v_ok + 1;
  raise notice 'T3 OK  — awaiting_authorization -> authorized acceptee';

  -- =================================================================
  -- T4 — RÈGLE VITALE : « j'ai envoyé » n'annule pas la garantie
  --      La pharmacie affirme avoir paye. C'est NON VERIFIE.
  --      Elle doit pouvoir atteindre pending_locum_confirmation,
  --      mais JAMAIS confirmed_exact.
  -- =================================================================
  update public.garanties_paiement set statut = 'pending_locum_confirmation'
   where id = v_garantie;
  v_ok := v_ok + 1;
  raise notice 'T4a OK — « j''ai envoye » -> pending_locum_confirmation acceptee';

  begin
    -- Tentative d'annulation SANS confirmation du pharmacien
    update public.garanties_paiement set statut = 'confirmed_exact'
     where id = v_garantie;
    raise exception 'T4_ECHEC';
  exception
    when check_violation then v_ok := v_ok + 1;
      raise notice 'T4b OK — annulation SANS confirme_par refusee';
    when others then
      if sqlerrm = 'T4_ECHEC' then
        v_echecs := v_echecs + 1;
        raise notice 'T4b ECHEC — la garantie a ete LIBEREE sans le pharmacien !';
      else raise; end if;
  end;

  begin
    -- Tentative d'annulation par la PHARMACIE (pas le pharmacien)
    update public.garanties_paiement
       set statut = 'confirmed_exact', confirme_par = v_pharmacie
     where id = v_garantie;
    raise exception 'T4_ECHEC2';
  exception
    when check_violation then v_ok := v_ok + 1;
      raise notice 'T4c OK — annulation par la PHARMACIE refusee';
    when others then
      if sqlerrm = 'T4_ECHEC2' then
        v_echecs := v_echecs + 1;
        raise notice 'T4c ECHEC — une pharmacie a libere sa propre garantie !';
      else raise; end if;
  end;

  -- =================================================================
  -- T5 — RÈGLE VITALE : amount_mismatch n'annule jamais
  -- =================================================================
  update public.garanties_paiement set statut = 'amount_mismatch' where id = v_garantie;
  v_ok := v_ok + 1;
  raise notice 'T5a OK — pending_locum_confirmation -> amount_mismatch acceptee';

  begin
    update public.garanties_paiement set statut = 'authorized' where id = v_garantie;
    raise exception 'T5_ECHEC';
  exception
    when check_violation then v_ok := v_ok + 1;
      raise notice 'T5b OK — retour arriere depuis amount_mismatch refuse';
    when others then
      if sqlerrm = 'T5_ECHEC' then
        v_echecs := v_echecs + 1;
        raise notice 'T5b ECHEC — amount_mismatch a pu revenir en arriere !';
      else raise; end if;
  end;

  begin
    update public.garanties_paiement set statut = 'confirmed_exact' where id = v_garantie;
    raise exception 'T5_ECHEC2';
  exception
    when check_violation then v_ok := v_ok + 1;
      raise notice 'T5c OK — amount_mismatch annule sans le pharmacien : refuse';
    when others then
      if sqlerrm = 'T5_ECHEC2' then
        v_echecs := v_echecs + 1;
        raise notice 'T5c ECHEC — amount_mismatch a LIBERE la garantie !';
      else raise; end if;
  end;

  -- =================================================================
  -- T6 — le pharmacien, lui, PEUT libérer sa garantie
  -- =================================================================
  update public.garanties_paiement
     set statut = 'confirmed_exact', confirme_par = v_pharmacien
   where id = v_garantie;
  v_ok := v_ok + 1;
  raise notice 'T6 OK  — le PHARMACIEN peut confirmer et liberer';

  -- =================================================================
  -- T7 — confirmed_exact est terminal
  -- =================================================================
  begin
    update public.garanties_paiement set statut = 'captured' where id = v_garantie;
    raise exception 'T7_ECHEC';
  exception
    when check_violation then v_ok := v_ok + 1;
      raise notice 'T7 OK  — capture apres confirmed_exact refusee';
    when others then
      if sqlerrm = 'T7_ECHEC' then
        v_echecs := v_echecs + 1;
        raise notice 'T7 ECHEC — une garantie annulee a pu etre capturee !';
      else raise; end if;
  end;

  -- =================================================================
  raise notice '-----------------------------------------------';
  if v_echecs = 0 then
    raise notice 'RESULTAT : % assertions, TOUTES PASSEES', v_ok;
  else
    raise exception 'RESULTAT : % ECHEC(S) sur % assertions — NE PAS DEPLOYER', v_echecs, v_ok + v_echecs;
  end if;
end $$;

rollback;

-- Confirme que le rollback a bien tout nettoyé.
select 'Apres ROLLBACK — contrats de test restants (doit etre 0) : ' ||
       (select count(*) from public.contrats where notes like 'TEST AUTOMATISE sql/86%')::text as nettoyage;
