-- =====================================================================
-- 88 — POINTAGE ARRIVÉE / DÉPART (toute la logique en RPC)
-- =====================================================================
-- Décisions de Robert, 2026-08-18 :
--   • Le DÉPART déclenche le financement.
--   • La preuve de présence est un INDICE, jamais une barrière. Le GPS
--     échoue à l'intérieur et en région ; un pharmacien privé de sa paie
--     par un mauvais relevé est le pire échec possible de ce produit.
--     On enregistre conforme/non conforme, on l'affiche à la pharmacie,
--     et on ne bloque JAMAIS le financement là-dessus.
--   • On garde UNIQUEMENT réussi/échoué + horodatage. Ni image, ni
--     coordonnées, jamais (Loi 25).
--
-- Toute la logique vit ici, dans Supabase, PAS dans le JavaScript des
-- pages : l'app Flutter appellera exactement ces fonctions
-- (voir PLAN-APP-MOBILE.md — 68 appels sb.rpc, zéro calcul dupliqué).
--
-- ---------------------------------------------------------------------
-- LIMITE CONNUE ET ASSUMÉE — à lire avant de promettre quoi que ce soit
-- ---------------------------------------------------------------------
-- La base ne contient AUCUNE coordonnée exacte de pharmacie. Le seul
-- repère disponible est le centroïde de RTA (les 3 premiers caractères du
-- code postal, table fsa_centroides). Une RTA couvre plusieurs kilomètres
-- en ville et beaucoup plus en région. La vérification de position est
-- donc de l'ordre du QUARTIER, pas de l'adresse.
--
-- C'est exactement pourquoi elle reste un indice. Deux colonnes
-- latitude/longitude sont ajoutées à profiles pour le jour où une
-- pharmacie posera son point exact elle-même (bouton « enregistrer la
-- position de ma pharmacie », depuis son propre appareil, sur place —
-- aucun service de géocodage, aucune dépendance). Tant qu'elles sont
-- vides, on retombe sur la RTA et le rayon est volontairement large.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Point de référence exact, pour plus tard. Vide = repli sur la RTA.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists latitude  double precision;
alter table public.profiles add column if not exists longitude double precision;

comment on column public.profiles.latitude is
  'Point exact de la pharmacie, pose par elle depuis son propre appareil. Vide = on retombe sur le centroide de RTA, beaucoup moins precis.';

-- Rayon toléré, réglable par l'admin.
alter table public.parametres_plateforme
  add column if not exists rayon_pointage_metres int not null default 5000
  check (rayon_pointage_metres between 100 and 100000);

-- ---------------------------------------------------------------------
-- 2) LES POINTAGES — réussi/échoué + horodatage. Rien d'autre.
-- ---------------------------------------------------------------------
create table if not exists public.pointages (
  id uuid primary key default gen_random_uuid(),
  candidature_id uuid not null references public.candidatures(id) on delete cascade,
  type text not null check (type in ('arrivee','depart')),
  moment timestamptz not null default now(),
  -- Résultat de la vérification. null = position non fournie (refus du
  -- navigateur, GPS indisponible) — ce n'est PAS un échec.
  position_conforme boolean,
  photo_fournie boolean not null default false,
  automatique boolean not null default false,
  created_at timestamptz not null default now(),
  unique (candidature_id, type)
);

comment on table public.pointages is
  'Arrivee/depart du pharmacien. AUCUNE image ni coordonnee n''est stockee : la position est verifiee a la volee puis jetee, seul position_conforme survit (Loi 25).';

create index if not exists idx_pointages_candidature on public.pointages(candidature_id);

-- ---------------------------------------------------------------------
-- 3) Distance en mètres entre deux points (haversine, même rayon
--    terrestre que cd_distance_km de sql/14)
-- ---------------------------------------------------------------------
create or replace function public.cd_distance_metres(
  lat1 double precision, lon1 double precision,
  lat2 double precision, lon2 double precision)
returns double precision
language sql immutable
as $$
  select 6371000 * 2 * asin(sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) *
      power(sin(radians(lon2 - lon1) / 2), 2)
  ));
$$;

-- ---------------------------------------------------------------------
-- 4) Le point de référence d'une pharmacie : exact si posé, sinon RTA
-- ---------------------------------------------------------------------
create or replace function public.cd_point_pharmacie(p_pharmacie uuid)
returns table (lat double precision, lng double precision, precis boolean)
language sql stable security definer set search_path = public
as $$
  select
    coalesce(p.latitude,  f.lat),
    coalesce(p.longitude, f.lng),
    (p.latitude is not null and p.longitude is not null)
  from public.profiles p
  left join public.fsa_centroides f
    on f.fsa = upper(left(regexp_replace(coalesce(p.code_postal,''), '\s', '', 'g'), 3))
  where p.id = p_pharmacie;
$$;

-- ---------------------------------------------------------------------
-- 5) POINTER — la seule porte d'entrée
--    p_lat / p_lon sont utilisés PUIS JETÉS. Ils ne sont jamais écrits.
-- ---------------------------------------------------------------------
create or replace function public.pointer(
  p_candidature uuid,
  p_type text,
  p_lat double precision default null,
  p_lon double precision default null,
  p_photo_fournie boolean default false
)
returns table (
  moment timestamptz,
  position_conforme boolean,
  heures_pointees numeric,
  heures_contrat numeric,
  ecart_minutes int,
  suite text
)
language plpgsql volatile security definer set search_path = public
as $$
declare
  c public.candidatures%rowtype;
  k public.contrats%rowtype;
  v_lat double precision; v_lng double precision; v_precis boolean;
  v_rayon int;
  v_conforme boolean := null;
  v_arrivee timestamptz;
  v_moment timestamptz := now();
  v_h_pointees numeric := null;
  v_h_contrat numeric := null;
  v_ecart int := null;
  v_suite text;
begin
  if p_type not in ('arrivee','depart') then
    raise exception 'Type de pointage invalide : %', p_type;
  end if;

  select * into c from public.candidatures where id = p_candidature;
  if not found then raise exception 'Mandat introuvable'; end if;

  -- Seul le pharmacien du mandat pointe. Pas d'exception admin ici :
  -- un pointage est une declaration personnelle de presence.
  if c.pharmacien_id <> auth.uid() then
    raise exception 'Seul le pharmacien de ce mandat peut pointer';
  end if;
  if c.statut <> 'accepte' then
    raise exception 'Ce mandat n''est pas actif';
  end if;

  select * into k from public.contrats where id = c.contrat_id;

  -- ---- Vérification de position : à la volée, puis on jette ----
  if p_lat is not null and p_lon is not null then
    select pp.lat, pp.lng, pp.precis into v_lat, v_lng, v_precis
      from public.cd_point_pharmacie(k.pharmacie_id) pp;
    select rayon_pointage_metres into v_rayon from public.parametres_plateforme where id = 1;
    if v_lat is not null and v_lng is not null then
      -- Repere de RTA : on double le rayon, un centroide n'est pas une adresse.
      v_conforme := public.cd_distance_metres(p_lat, p_lon, v_lat, v_lng)
                    <= (case when coalesce(v_precis,false) then v_rayon else v_rayon * 2 end);
    end if;
  end if;
  -- p_lat / p_lon sortent de portee ici. Ils ne sont ecrits nulle part.

  insert into public.pointages (candidature_id, type, moment, position_conforme, photo_fournie)
  values (p_candidature, p_type, v_moment, v_conforme, coalesce(p_photo_fournie,false))
  on conflict (candidature_id, type) do update
    set moment = excluded.moment,
        position_conforme = excluded.position_conforme,
        photo_fournie = excluded.photo_fournie;

  -- ---- Le départ calcule l'écart avec le contrat ----
  if p_type = 'depart' then
    select pt.moment into v_arrivee
      from public.pointages pt
     where pt.candidature_id = p_candidature and pt.type = 'arrivee';

    if v_arrivee is null then
      v_suite := 'depart_sans_arrivee';
    else
      v_h_pointees := round((extract(epoch from (v_moment - v_arrivee)) / 3600.0)::numeric, 2);
      v_h_contrat := round((
        extract(epoch from (
          coalesce(c.heure_fin_proposee, k.heure_fin) - coalesce(c.heure_debut_proposee, k.heure_debut)
        )) / 3600.0
        + case when coalesce(c.heure_fin_proposee, k.heure_fin)
                    <= coalesce(c.heure_debut_proposee, k.heure_debut) then 24 else 0 end
      )::numeric, 2);
      v_ecart := round((v_h_pointees - v_h_contrat) * 60)::int;

      -- Décision 7 : une BAISSE se finance tout de suite (elle est en
      -- faveur de la pharmacie) ; une HAUSSE demande son accord.
      if v_ecart <= 0 then
        v_suite := 'financer_maintenant';
      else
        v_suite := 'approbation_pharmacie_requise';
      end if;
    end if;
  else
    v_suite := 'arrivee_enregistree';
  end if;

  return query select v_moment, v_conforme, v_h_pointees, v_h_contrat, v_ecart, v_suite;
end;
$$;
revoke all on function public.pointer(uuid, text, double precision, double precision, boolean) from public, anon;
grant execute on function public.pointer(uuid, text, double precision, double precision, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 6) ÉTAT — pour l'écran (et plus tard l'app)
-- ---------------------------------------------------------------------
create or replace function public.etat_pointage(p_candidature uuid)
returns table (
  arrivee timestamptz, arrivee_conforme boolean, arrivee_photo boolean,
  depart timestamptz,  depart_conforme boolean,  depart_photo boolean,
  heures_pointees numeric
)
language sql stable security definer set search_path = public
as $$
  select
    a.moment, a.position_conforme, a.photo_fournie,
    d.moment, d.position_conforme, d.photo_fournie,
    case when a.moment is not null and d.moment is not null
         then round((extract(epoch from (d.moment - a.moment)) / 3600.0)::numeric, 2) end
  from public.candidatures c
  join public.contrats k on k.id = c.contrat_id
  left join public.pointages a on a.candidature_id = c.id and a.type = 'arrivee'
  left join public.pointages d on d.candidature_id = c.id and d.type = 'depart'
  where c.id = p_candidature
    and (c.pharmacien_id = auth.uid() or k.pharmacie_id = auth.uid() or public.est_admin());
$$;
revoke all on function public.etat_pointage(uuid) from public, anon;
grant execute on function public.etat_pointage(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7) VERROUS — lecture par les deux parties, écriture par pointer() seul
-- ---------------------------------------------------------------------
alter table public.pointages enable row level security;
drop policy if exists pointages_select on public.pointages;
create policy pointages_select on public.pointages
  for select using (
    exists (
      select 1 from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      where c.id = pointages.candidature_id
        and (c.pharmacien_id = auth.uid() or k.pharmacie_id = auth.uid() or public.est_admin())
    )
  );
-- Aucune politique insert/update/delete : tout passe par pointer().

select 'table pointages creee' as etape,
       (select count(*) from public.pointages) as lignes,
       (select rayon_pointage_metres from public.parametres_plateforme where id=1) as rayon_metres;
