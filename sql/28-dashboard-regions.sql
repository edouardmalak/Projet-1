-- =====================================================================
-- C-DIRECT · SQL 28 — TABLEAU DE BORD : RÉGIONS + CONTRATS À RISQUE
-- (Zone Admin B)
-- À exécuter dans Supabase → SQL Editor, APRÈS 27-comms-monitoring.sql.
-- Idempotent (create or replace). Lecture seule — aucune table modifiée.
-- =====================================================================

-- ---------------------------------------------------------------------
-- get_contrats_a_risque — contrats ENCORE OUVERTS dont le début est à
-- moins de 48 h (et pas déjà passé). Triés par urgence (le plus proche
-- en premier).
-- ---------------------------------------------------------------------
create or replace function public.get_contrats_a_risque()
returns table (
  id uuid, numero_reference text, date_contrat date, heure_debut time,
  nom_pharmacie text, ville text, tarif_horaire numeric, heures_restantes numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select k.id, k.numero_reference, k.date_contrat, k.heure_debut,
           pe.nom_pharmacie, pe.ville, k.tarif_horaire,
           round(extract(epoch from (
             (k.date_contrat + k.heure_debut) at time zone 'America/Toronto' - now()
           )) / 3600.0, 1)
      from public.contrats k
      join public.profiles pe on pe.id = k.pharmacie_id
     where k.statut = 'ouvert'
       and (k.date_contrat + k.heure_debut) at time zone 'America/Toronto' > now()
       and (k.date_contrat + k.heure_debut) at time zone 'America/Toronto' - now() <= interval '48 hours'
     order by (k.date_contrat + k.heure_debut) asc;
end;
$$;
revoke all on function public.get_contrats_a_risque() from public, anon;
grant execute on function public.get_contrats_a_risque() to authenticated;

-- ---------------------------------------------------------------------
-- get_dashboard_regions — remplissage + délai médian, groupés par ville
-- de la pharmacie (proxy « région » — les codes postaux ne sont pas
-- systématiquement remplis pour permettre un vrai regroupement FSA).
-- ---------------------------------------------------------------------
create or replace function public.get_dashboard_regions()
returns table (
  region text, contrats int, remplis int,
  taux_remplissage int, delai_median_h numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    with base as (
      select coalesce(nullif(pe.ville,''), 'Non précisé') as region,
             k.statut,
             (select c.updated_at from public.candidatures c
               where c.contrat_id = k.id and c.statut = 'accepte'
               order by c.updated_at desc limit 1) as rempli_le,
             k.created_at
        from public.contrats k
        join public.profiles pe on pe.id = k.pharmacie_id
    )
    select b.region,
           count(*)::int,
           count(*) filter (where b.statut in ('attribue','complete'))::int,
           round(100.0 * count(*) filter (where b.statut in ('attribue','complete'))
                 / nullif(count(*),0)::numeric)::int,
           round(extract(epoch from (
             percentile_cont(0.5) within group (order by (b.rempli_le - b.created_at))
               filter (where b.rempli_le is not null)
           )) / 3600.0, 1)
      from base b
     group by b.region
     order by count(*) desc;
end;
$$;
revoke all on function public.get_dashboard_regions() from public, anon;
grant execute on function public.get_dashboard_regions() to authenticated;
