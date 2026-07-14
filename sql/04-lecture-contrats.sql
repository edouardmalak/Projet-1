-- =====================================================================
-- C-DIRECT · PHASE 1 · SQL 04 — LECTURE DES CONTRATS (RPC)
-- À exécuter APRÈS 03-rls.sql.
-- Pourquoi des RPC : la RLS de profiles ne laisse PAS un pharmacien
-- lire le profil d'une pharmacie. Le tableau et la fiche ont pourtant
-- besoin de ville + logiciel. Ces fonctions security definer exposent
-- UNIQUEMENT ces deux champs, jamais le reste du profil.
-- =====================================================================

-- ---------------------------------------------------------------------
-- RPC · get_contrats_ouverts — tableau des contrats (pharmacien/admin)
-- Contrats ouverts, plus récents d'abord, + ville/logiciel de la
-- pharmacie + indicateur « j'ai déjà postulé ».
-- ---------------------------------------------------------------------
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, deja_postule boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (public.mon_role() in ('pharmacien','admin')) then
    raise exception 'Accès refusé';
  end if;
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.statut, p.ville, p.logiciel,
           exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid())
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- RPC · get_contrat_fiche — fiche complète par numéro de référence
-- Accès : admin · pharmacie propriétaire · pharmacien (contrat ouvert
-- ou auquel il a postulé). Renvoie aussi le statut de MA candidature.
-- ---------------------------------------------------------------------
create or replace function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text,
  ma_candidature_statut text, est_ma_pharmacie boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.rx_jour_semaine, k.rx_jour_weekend,
           k.seul_pharmacien, k.atp_presente, k.services,
           k.notes, k.statut, k.created_at,
           p.ville, p.logiciel,
           (select c.statut from public.candidatures c
             where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           (k.pharmacie_id = auth.uid())
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.numero_reference = upper(trim(p_ref))
       and (
         public.est_admin()
         or k.pharmacie_id = auth.uid()
         or (public.mon_role() = 'pharmacien'
             and (k.statut = 'ouvert' or public.a_postule(k.id)))
       );
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;
