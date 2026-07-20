-- =====================================================================
-- C-DIRECT · SQL 13 — CODE POSTAL DE LA PHARMACIE DANS LES RPC DE LECTURE
-- À exécuter dans Supabase → SQL Editor (idempotent : create or replace).
--
-- Pourquoi : Phase 2.3 (distance + estimation km / per diem / hébergement).
-- Le tableau et la fiche calculent la distance FSA entre le code postal du
-- pharmacien (son profil) et celui de la pharmacie. La RLS empêche un
-- pharmacien de lire le profil d'une pharmacie ; ces RPC security definer
-- exposent donc UNIQUEMENT le code postal (comme elles exposent déjà
-- ville + logiciel), jamais le reste du profil.
--
-- Sans ce fichier, l'interface fonctionne quand même : elle affiche
-- l'estimation de base (tarif × heures) et masque simplement les lignes
-- de distance. Après exécution, les km + indemnités s'activent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- get_contrats_ouverts — + code_postal de la pharmacie
-- (drop d'abord : on change la liste des colonnes retournées)
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean
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
           k.statut, p.ville, p.logiciel, p.code_postal,
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
-- get_contrat_fiche — + code_postal de la pharmacie
-- (drop d'abord : on change la liste des colonnes retournées)
-- ---------------------------------------------------------------------
drop function if exists public.get_contrat_fiche(text);
create or replace function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text, code_postal text,
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
           p.ville, p.logiciel, p.code_postal,
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
