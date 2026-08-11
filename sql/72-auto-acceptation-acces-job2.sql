-- =====================================================================
-- C-DIRECT · SQL 72 — AUTO-ACCEPTATION (JOB 1/2) · DONNÉES EXPOSÉES POUR LE JOB 2
-- À exécuter APRÈS 71-auto-acceptation-cron.sql.
--
-- Aucune interface ici (Job 2) — seulement les LECTURES dont l'interface
-- aura besoin, par RPC security definer (jamais d'accès brut aux tables) :
--   · auto_acceptation_infos_publiques : interrupteur + prime courante,
--     pour l'écran de publication de quart côté pharmacie (double taux)
--   · mes_mois_confirmes : les mois confirmés du pharmacien connecté
--   · mes_rejets_auto_acceptation : les refus du pharmacien connecté
--     depuis match_log — via RPC, PAS la table (le journal complet reste
--     admin seulement)
--   · reglages admin + historique : déjà couverts par la RLS admin de
--     SQL 68 (select direct possible pour l'admin).
--
-- Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Interrupteur + prime courante (tout utilisateur connecté — la
--    pharmacie doit voir le double taux AVANT de publier).
-- ---------------------------------------------------------------------
create or replace function public.auto_acceptation_infos_publiques()
returns table (feature_enabled boolean, premium_per_hour numeric)
language sql stable security definer set search_path = public
as $$
  select feature_enabled, premium_per_hour
    from public.auto_accept_admin_settings where id = 1;
$$;
revoke all on function public.auto_acceptation_infos_publiques() from public, anon;
grant execute on function public.auto_acceptation_infos_publiques() to authenticated;

-- ---------------------------------------------------------------------
-- 2) Mois confirmés du pharmacien connecté (réglages + calendrier, Job 2).
-- ---------------------------------------------------------------------
create or replace function public.mes_mois_confirmes()
returns table (mois date, confirme_le timestamptz)
language sql stable security definer set search_path = public
as $$
  select month, confirmed_at
    from public.locum_calendar_confirmations
   where locum_id = auth.uid()
   order by month desc;
$$;
revoke all on function public.mes_mois_confirmes() from public, anon;
grant execute on function public.mes_mois_confirmes() to authenticated;

-- ---------------------------------------------------------------------
-- 3) Mes refus de matching — pourquoi je n'ai pas eu tel quart.
--    Expose UNIQUEMENT les lignes du pharmacien connecté, avec le
--    contexte minimal du contrat. Le journal complet (tous pharmaciens)
--    reste réservé à l'admin.
-- ---------------------------------------------------------------------
create or replace function public.mes_rejets_auto_acceptation(p_limite int default 50)
returns table (
  evalue_le timestamptz, resultat text, porte text, detail jsonb,
  numero_reference text, date_contrat date, ville text
)
language sql stable security definer set search_path = public
as $$
  select m.evaluated_at, m.result, m.rejection_gate, m.detail,
         k.numero_reference, k.date_contrat, p.ville
    from public.match_log m
    join public.contrats k on k.id = m.shift_id
    left join public.profiles p on p.id = k.pharmacie_id
   where m.locum_id = auth.uid()
   order by m.evaluated_at desc
   limit greatest(1, least(coalesce(p_limite, 50), 200));
$$;
revoke all on function public.mes_rejets_auto_acceptation(int) from public, anon;
grant execute on function public.mes_rejets_auto_acceptation(int) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution (connecté en pharmacien de test) :
--   select * from public.auto_acceptation_infos_publiques();  -- false, 0
--   select * from public.mes_mois_confirmes();
--   select * from public.mes_rejets_auto_acceptation(10);
-- =====================================================================
