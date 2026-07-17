-- =====================================================================
-- C-DIRECT · PHASE 3 · SQL 08 — ENVOI + SUIVI DES PAIEMENTS + PG_CRON
-- À exécuter APRÈS 07-factures.sql, dans Supabase → SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- RPC · envoyer_facture — le pharmacien envoie son brouillon :
-- statut → 'envoyee', date_envoi = maintenant,
-- date_echeance = + regles_reseau.delai_paiement_jours.
-- ---------------------------------------------------------------------
create or replace function public.envoyer_facture(p_facture uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_delai int;
begin
  select delai_paiement_jours into v_delai from public.regles_reseau where id = 1;

  update public.factures f
     set statut = 'envoyee',
         date_envoi = now(),
         date_echeance = current_date + coalesce(v_delai, 30)
    from public.candidatures c
   where f.id = p_facture
     and c.id = f.candidature_id
     and f.statut = 'brouillon'
     and (c.pharmacien_id = auth.uid() or public.est_admin());
  if not found then
    raise exception 'Facture introuvable ou déjà envoyée';
  end if;
end;
$$;
revoke all on function public.envoyer_facture(uuid) from public, anon;
grant execute on function public.envoyer_facture(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- RPC · envoyer_factures_mois — « Envoyer les factures du mois » :
-- envoie d'un coup TOUS les brouillons du pharmacien connecté.
-- Renvoie le nombre de factures envoyées.
-- ---------------------------------------------------------------------
create or replace function public.envoyer_factures_mois()
returns int
language plpgsql security definer set search_path = public
as $$
declare v_delai int; v_n int;
begin
  select delai_paiement_jours into v_delai from public.regles_reseau where id = 1;

  with maj as (
    update public.factures f
       set statut = 'envoyee',
           date_envoi = now(),
           date_echeance = current_date + coalesce(v_delai, 30)
      from public.candidatures c
     where c.id = f.candidature_id
       and f.statut = 'brouillon'
       and c.pharmacien_id = auth.uid()
    returning f.id
  )
  select count(*) into v_n from maj;
  return v_n;
end;
$$;
revoke all on function public.envoyer_factures_mois() from public, anon;
grant execute on function public.envoyer_factures_mois() to authenticated;

-- ---------------------------------------------------------------------
-- RPC · marquer_facture_payee — la pharmacie marque payée ; le
-- pharmacien peut aussi confirmer la réception du paiement.
-- ---------------------------------------------------------------------
create or replace function public.marquer_facture_payee(p_facture uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.factures f
     set statut = 'payee',
         date_paiement = now()
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
   where f.id = p_facture
     and c.id = f.candidature_id
     and f.statut in ('envoyee','en_retard')
     and (k.pharmacie_id = auth.uid() or c.pharmacien_id = auth.uid() or public.est_admin());
  if not found then
    raise exception 'Facture introuvable ou non payable (envoyée / en retard seulement)';
  end if;
end;
$$;
revoke all on function public.marquer_facture_payee(uuid) from public, anon;
grant execute on function public.marquer_facture_payee(uuid) to authenticated;

-- =====================================================================
-- PG_CRON — bascule quotidienne 'envoyee' → 'en_retard' passé
-- date_echeance. Un contrôle côté client n'est pas fiable (personne
-- n'a besoin d'ouvrir le site pour que le statut soit juste) : la
-- bascule vit DANS la base. (Le SMS de rappel viendra en Phase 5.)
--
-- Supabase : Database → Extensions → activer pg_cron si nécessaire —
-- le create extension ci-dessous le fait aussi.
-- =====================================================================
create extension if not exists pg_cron;

-- (ré)planification idempotente : retire l'ancienne tâche si présente
do $$
begin
  perform cron.unschedule('factures-en-retard');
exception when others then
  null; -- pas encore planifiée : rien à retirer
end;
$$;

-- Tous les jours à 08:05 UTC (≈ 3–4 h du matin au Québec)
select cron.schedule(
  'factures-en-retard',
  '5 8 * * *',
  $$
    update public.factures
       set statut = 'en_retard'
     where statut = 'envoyee'
       and date_echeance < current_date
  $$
);

-- Vérification : select jobname, schedule, active from cron.job;
