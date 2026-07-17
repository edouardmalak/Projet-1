-- =====================================================================
-- C-DIRECT · PHASE 3 · SQL 10 — ADMIN : SURCHARGE MANUELLE DE STATUT
-- À exécuter APRÈS 09-annulation.sql, dans Supabase → SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- RPC · admin_maj_facture_statut — surcharge manuelle d'un statut de
-- facture avec NOTE D'AUDIT obligatoire, journalisée dans le fil de la
-- candidature (schéma figé : le journal JSON de candidatures.message
-- sert de piste d'audit — visible par l'admin).
-- Les dates suivent le statut :
--   envoyee   → date_envoi/date_echeance posées si absentes
--   payee     → date_paiement posée si absente
--   brouillon → dates remises à zéro
--   en_retard → dates d'envoi conservées
-- ---------------------------------------------------------------------
create or replace function public.admin_maj_facture_statut(
  p_facture uuid, p_statut text, p_note text
)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_cand uuid; v_delai int;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_statut not in ('brouillon','envoyee','payee','en_retard') then
    raise exception 'Statut invalide : %', p_statut;
  end if;
  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Note d''audit obligatoire (min. 3 caractères)';
  end if;

  select delai_paiement_jours into v_delai from public.regles_reseau where id = 1;

  update public.factures
     set statut = p_statut,
         date_envoi = case
           when p_statut = 'brouillon' then null
           when p_statut in ('envoyee','en_retard','payee') then coalesce(date_envoi, now())
         end,
         date_echeance = case
           when p_statut = 'brouillon' then null
           when p_statut in ('envoyee','en_retard','payee')
             then coalesce(date_echeance, current_date + coalesce(v_delai, 30))
         end,
         date_paiement = case
           when p_statut = 'payee' then coalesce(date_paiement, now())
           else null
         end
   where id = p_facture
   returning candidature_id into v_cand;
  if v_cand is null then raise exception 'Facture introuvable'; end if;

  -- piste d'audit ('auto' → aucun courriel)
  update public.candidatures
     set message = public.ajouter_jalon(message, jsonb_build_object(
       'etape','facture_admin','par','admin',
       'statut',p_statut,'note',trim(p_note),'auto',true))
   where id = v_cand;
end;
$$;
revoke all on function public.admin_maj_facture_statut(uuid, text, text) from public, anon;
grant execute on function public.admin_maj_facture_statut(uuid, text, text) to authenticated;
