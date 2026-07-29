-- =====================================================================
-- C-DIRECT · SQL 36 — Instant Booking : acceptation automatique
-- des candidatures d'un pharmacien FAVORI, uniquement si la pharmacie a
-- explicitement activé confirmation_auto_favoris (off par défaut, sql/35).
--
-- SÉCURITÉ : cette fonction ne vérifie PAS auth.uid() comme
-- accepter_candidature() (RPC existante, usage humain) — elle est réservée
-- au Worker (clé service_role) et RE-VÉRIFIE elle-même toutes les
-- conditions (favori, toggle actif, non exclu, type 'instantanee') avant
-- d'agir. Aucun grant à authenticated/anon : impossible à appeler depuis
-- le site ou un jeton usager, seul le service_role le peut.
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

  if not exists (
    select 1 from public.favoris_pharmaciens
     where pharmacie_id = v_pharmacie and pharmacien_id = v_pharmacien
  ) then
    return false;
  end if;

  if public.est_exclu(v_pharmacien, v_pharmacie) then
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
  perform public.appliquer_indemnites(v_contrat, v_distance);
  return true;
end;
$$;

revoke all on function public.accepter_candidature_auto(uuid) from public, anon, authenticated;
grant execute on function public.accepter_candidature_auto(uuid) to service_role;
