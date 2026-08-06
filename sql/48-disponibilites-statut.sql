-- 48 — Statut des disponibilités (disponible / indisponible)
-- Permet au pharmacien de marquer explicitement des journées comme
-- INDISPONIBLES (et pas seulement "non renseignées"), pour :
--   - bloquer sa propre candidature sur un contrat qui tombe ce jour-là
--   - retirer ces journées du calcul « N pharmaciens compatibles » côté pharmacie
-- Rétrocompatible : toute ligne existante devient 'disponible' (comportement inchangé).

alter table public.disponibilites
  add column if not exists statut text not null default 'disponible';

alter table public.disponibilites
  drop constraint if exists disponibilites_statut_check;
alter table public.disponibilites
  add constraint disponibilites_statut_check check (statut in ('disponible','indisponible'));

create index if not exists idx_disponibilites_statut on public.disponibilites(pharmacien_id, statut);

-- ---------------------------------------------------------------------
-- Recalcul de compter_compatibles() : une journée marquée INDISPONIBLE
-- exclut désormais le pharmacien pour cette date précise, même si le mois
-- n'est pas autrement calendrié. Le heuristique « pas de calendrier ce mois
-- => présumé compatible » ne porte plus que sur les lignes 'disponible',
-- pour ne pas pénaliser tout le mois quand une seule journée est bloquée.
create or replace function public.compter_compatibles(p_date date, p_tarif numeric)
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_pe public.profiles; n integer;
begin
  select * into v_pe from public.profiles where id = auth.uid();
  if v_pe.role not in ('pharmacie','admin') then raise exception 'Accès refusé'; end if;

  select count(*) into n from public.profiles pn
   where pn.role = 'pharmacien' and coalesce(pn.approuve,false) = true
     and (v_pe.code_postal is null or pn.code_postal is null or pn.rayon_deplacement_km is null
          or public.cd_distance_km(pn.code_postal, v_pe.code_postal) <= pn.rayon_deplacement_km)
     and (pn.tarif_horaire_min is null or pn.tarif_horaire_min <= p_tarif)
     and (v_pe.logiciel is null or pn.logiciels is null or v_pe.logiciel = any(pn.logiciels))
     and not exists (
       select 1 from public.disponibilites d
        where d.pharmacien_id = pn.id and d.date_dispo = p_date and d.statut = 'indisponible'
     )
     and (
       not exists (select 1 from public.disponibilites d
                    where d.pharmacien_id = pn.id
                      and date_trunc('month', d.date_dispo) = date_trunc('month', p_date)
                      and d.statut = 'disponible')
       or exists (select 1 from public.disponibilites d
                   where d.pharmacien_id = pn.id and d.date_dispo = p_date and d.statut = 'disponible')
     );
  return n;
end; $$;
revoke all on function public.compter_compatibles(date, numeric) from public, anon;
grant execute on function public.compter_compatibles(date, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- Helper pour le pharmacien connecté : ses dates indisponibles à venir,
-- utilisé par contrats.html / contrat.html pour le drapeau rouge / blocage.
create or replace function public.mes_dates_indisponibles()
returns setof date language sql stable security definer set search_path = public as $$
  select date_dispo from public.disponibilites
   where pharmacien_id = auth.uid() and statut = 'indisponible' and date_dispo >= current_date
   order by date_dispo;
$$;
revoke all on function public.mes_dates_indisponibles() from public, anon;
grant execute on function public.mes_dates_indisponibles() to authenticated;
