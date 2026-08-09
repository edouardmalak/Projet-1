-- =====================================================================
-- C-DIRECT · SQL 62 — Restaure les gardes d'accepter_candidature_auto
-- (Instant Booking), perdues par dérive en production.
--
-- CONTEXTE (découvert le 2026-08-08 en exécutant sql/61, corrigé ici le
-- 2026-08-09) : la version LIVE de accepter_candidature_auto() ne
-- vérifie plus ni type_candidature='instantanee', ni le toggle
-- confirmation_auto_favoris, ni le statut favori, ni les exclusions —
-- elle accepte automatiquement toute candidature 'propose'/'contre_offre'
-- dès que le Worker l'appelle, et elle retourne void (le Worker attendait
-- un boolean, donc son suivi SMS de confirmation ne se déclenchait pas).
--
-- CETTE VERSION restaure toutes les gardes de sql/36, plus :
--   · state='trusted' exigé sur le favori (sql/61 : un favori 'muted' ou
--     'blocked' ne doit jamais déclencher une acceptation automatique) ;
--   · est_bloque() (sql/61) au lieu d'est_exclu() seul — couvre
--     l'exclusion admin ET les blocages libre-service des deux tables ;
--   · appliquer_indemnites() à 3 arguments (sql/52) pour conserver le
--     correctif hébergement-en-nature ;
--   · returns boolean, comme le Worker (mis à jour le 2026-08-09)
--     l'attend.
--
-- Le Worker fait désormais les mêmes vérifications AVANT d'appeler cette
-- fonction (défense en profondeur) — les deux couches doivent rester
-- d'accord.
--
-- À exécuter dans Supabase → SQL Editor.
-- =====================================================================

create or replace function public.accepter_candidature_auto(p_candidature uuid)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_contrat uuid; v_distance numeric; v_pharmacie uuid; v_pharmacien uuid;
  v_toggle boolean; v_type text; v_statut_contrat text;
begin
  select c.contrat_id, c.distance_km, k.pharmacie_id, c.pharmacien_id,
         c.type_candidature, k.statut
    into v_contrat, v_distance, v_pharmacie, v_pharmacien, v_type, v_statut_contrat
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
   where c.id = p_candidature
     and c.statut = 'propose';

  if v_contrat is null or v_statut_contrat <> 'ouvert' then
    return false;
  end if;

  -- Instant Booking : uniquement les candidatures au tarif affiché
  -- (jamais une contre-offre — un prix différent mérite un regard humain).
  if v_type <> 'instantanee' then
    return false;
  end if;

  select confirmation_auto_favoris into v_toggle
    from public.profiles where id = v_pharmacie;
  if not coalesce(v_toggle, false) then
    return false;
  end if;

  -- Favori de confiance uniquement (sql/61 : state 'muted'/'blocked'
  -- ne compte pas).
  if not exists (
    select 1 from public.favoris_pharmaciens
     where pharmacie_id = v_pharmacie and pharmacien_id = v_pharmacien
       and state = 'trusted'
  ) then
    return false;
  end if;

  -- Exclusion admin OU blocage libre-service (les deux directions).
  if public.est_bloque(v_pharmacien, v_pharmacie) then
    return false;
  end if;

  update public.candidatures
     set statut = 'accepte',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','accepte','par','instant_booking'))
   where id = p_candidature;

  update public.candidatures
     set statut = 'refuse',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','refuse','par','pharmacie','auto',true))
   where contrat_id = v_contrat and id <> p_candidature
     and statut in ('propose','contre_offre');

  update public.contrats set statut = 'attribue' where id = v_contrat;
  perform public.appliquer_indemnites(v_contrat, v_distance, p_candidature);
  return true;
end;
$$;

revoke all on function public.accepter_candidature_auto(uuid) from public, anon, authenticated;
grant execute on function public.accepter_candidature_auto(uuid) to service_role;

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   select pg_get_functiondef('public.accepter_candidature_auto(uuid)'::regprocedure);
--     -> doit contenir « returns boolean », « instantanee »,
--        « confirmation_auto_favoris », « state = 'trusted' » et
--        « est_bloque ».
-- ---------------------------------------------------------------------
