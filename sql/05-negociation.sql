-- =====================================================================
-- C-DIRECT · PHASE 2 · SQL 05 — NÉGOCIATION 3 ÉTAPES
-- À exécuter APRÈS 04-lecture-contrats.sql.
-- Le fil de négociation est journalisé en JSON dans candidatures.message
-- (schéma figé — aucune table modifiée). Les colonnes tarif_propose /
-- heure_*_proposee / statut reflètent toujours le dernier état.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper : ajouter un jalon au journal (tolère null / texte libre)
-- ---------------------------------------------------------------------
create or replace function public.ajouter_jalon(p_message text, p_jalon jsonb)
returns text language plpgsql immutable
as $$
declare j jsonb;
begin
  begin
    j := coalesce(p_message::jsonb, '[]'::jsonb);
    if jsonb_typeof(j) <> 'array' then j := '[]'::jsonb; end if;
  exception when others then
    j := '[]'::jsonb;
  end;
  return (j || jsonb_build_array(p_jalon || jsonb_build_object('quand', now())))::text;
end;
$$;

-- ---------------------------------------------------------------------
-- Helper : per diem / hébergement automatiques (le moteur de règles
-- décide — jamais la pharmacie). Distance ALLER SIMPLE en km.
-- ---------------------------------------------------------------------
create or replace function public.appliquer_indemnites(p_contrat uuid, p_distance numeric)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.regles_reseau%rowtype;
begin
  select * into r from public.regles_reseau where id = 1;
  update public.contrats
     set per_diem    = coalesce(p_distance >= r.seuil_per_diem_km, false),
         hebergement = coalesce(p_distance >= r.seuil_hebergement_km, false)
   where id = p_contrat;
end;
$$;

-- ---------------------------------------------------------------------
-- get_candidats v2 — champs de négociation complets
-- (retour modifié → drop obligatoire)
-- ---------------------------------------------------------------------
drop function if exists public.get_candidats(uuid);
create function public.get_candidats(p_contrat uuid)
returns table (
  candidature_id uuid, statut text, type_candidature text,
  tarif_propose numeric, heure_debut_proposee time, heure_fin_proposee time,
  distance_km numeric, message text,
  cree_le timestamptz, maj_le timestamptz,
  pharmacien_id uuid, nom text, prenom text, ville_base text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (
    public.est_admin()
    or exists (select 1 from public.contrats k
                where k.id = p_contrat and k.pharmacie_id = auth.uid())
  ) then
    raise exception 'Accès refusé';
  end if;
  return query
    select c.id, c.statut, c.type_candidature,
           c.tarif_propose, c.heure_debut_proposee, c.heure_fin_proposee,
           c.distance_km, c.message,
           c.created_at, c.updated_at,
           p.id, p.nom, p.prenom, p.ville_base
      from public.candidatures c
      join public.profiles p on p.id = c.pharmacien_id
     where c.contrat_id = p_contrat
     order by c.created_at;
end;
$$;
revoke all on function public.get_candidats(uuid) from public, anon;
grant execute on function public.get_candidats(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- accepter_candidature v2 — journal + indemnités automatiques
-- (pharmacie accepte une candidature 'propose' — un geste)
-- ---------------------------------------------------------------------
create or replace function public.accepter_candidature(p_candidature uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_contrat uuid; v_distance numeric;
begin
  select c.contrat_id, c.distance_km into v_contrat, v_distance
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
   where c.id = p_candidature
     and (k.pharmacie_id = auth.uid() or public.est_admin())
     and k.statut = 'ouvert'
     and c.statut in ('propose','contre_offre');
  if v_contrat is null then
    raise exception 'Candidature introuvable ou contrat non ouvert';
  end if;

  update public.candidatures
     set statut = 'accepte',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','accepte','par','pharmacie'))
   where id = p_candidature;

  update public.candidatures
     set statut = 'refuse',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','refuse','par','pharmacie','auto',true))
   where contrat_id = v_contrat and id <> p_candidature
     and statut in ('propose','contre_offre');

  update public.contrats set statut = 'attribue' where id = v_contrat;
  perform public.appliquer_indemnites(v_contrat, v_distance);
end;
$$;
revoke all on function public.accepter_candidature(uuid) from public, anon;
grant execute on function public.accepter_candidature(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- accepter_contre_offre — le pharmacien accepte les termes contrés :
-- accepte aux termes courants · autres refusées · contrat attribué.
-- (RPC nécessaire : la RLS n'autorise pas le pharmacien à modifier
-- le contrat ni les candidatures des autres.)
-- ---------------------------------------------------------------------
create or replace function public.accepter_contre_offre(p_candidature uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_contrat uuid; v_distance numeric;
begin
  select c.contrat_id, c.distance_km into v_contrat, v_distance
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
   where c.id = p_candidature
     and c.pharmacien_id = auth.uid()
     and c.statut = 'contre_offre'
     and k.statut = 'ouvert';
  if v_contrat is null then
    raise exception 'Contre-offre introuvable ou contrat non ouvert';
  end if;

  update public.candidatures
     set statut = 'accepte',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','accepte','par','pharmacien'))
   where id = p_candidature;

  update public.candidatures
     set statut = 'refuse',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','refuse','par','pharmacie','auto',true))
   where contrat_id = v_contrat and id <> p_candidature
     and statut in ('propose','contre_offre');

  update public.contrats set statut = 'attribue' where id = v_contrat;
  perform public.appliquer_indemnites(v_contrat, v_distance);
end;
$$;
revoke all on function public.accepter_contre_offre(uuid) from public, anon;
grant execute on function public.accepter_contre_offre(uuid) to authenticated;
