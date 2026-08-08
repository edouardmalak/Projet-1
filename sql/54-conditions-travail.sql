-- =====================================================================
-- C-DIRECT · SQL 54 — Feature "Conditions de travail" (transparence)
--
-- La quasi-totalité de cette feature existe déjà : rx_jour_semaine/
-- rx_jour_weekend (volume), seul_pharmacien/atp_presente (personnel),
-- services (checklist), logiciel — tous déjà sur profiles (défaut
-- pharmacie) ET contrats (copié à la publication), déjà affichés sur
-- contrat.html. Seuls deux champs manquent réellement : l'automatisation
-- (robot) et le dîner couvert. Le stationnement existe aussi déjà
-- (profiles.info_stationnement) mais reste volontairement gaté après
-- confirmation (décision Robert 2026-08-08 — ne pas l'exposer avant
-- candidature, pour ne pas affaiblir la protection anti-contournement).
--
-- IMPORTANT : get_contrats_ouverts() et get_contrat_fiche() ont été
-- patchées plusieurs fois depuis leur création (exclusions sql/21,
-- profession_recherchee sql/50, fix id ambigu sql/51, hébergement en
-- nature sql/52 — qui a aussi restauré un bug de sql/50 ayant fait
-- disparaître pharmacie_nom/pharmacien_nom/réputation). Cette migration
-- reprend le corps EXACT de sql/52 (la version actuellement live) et
-- ajoute seulement les nouvelles colonnes — aucune logique existante
-- n'est retirée ou modifiée.
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Colonnes
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists has_automation boolean not null default false; -- pharmacie : robot / auto-dispense (défaut)
alter table public.contrats add column if not exists has_automation boolean not null default false;  -- copié du profil à la publication, comme rx_jour_semaine/services
alter table public.contrats add column if not exists lunch_coverage boolean;                          -- dîner couvert pour CE quart ; null = non précisé (pas de défaut profil, propre à chaque quart)

-- ---------------------------------------------------------------------
-- 2) get_contrats_ouverts — reprend sql/52 tel quel + ajoute les champs
--    "conditions" pour le résumé compact sur la liste (jusqu'ici seule
--    get_contrat_fiche les retournait, pas la liste).
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean,
  profession_recherchee text, hebergement_offerte boolean,
  rx_jour_semaine int, rx_jour_weekend int, seul_pharmacien boolean,
  atp_presente boolean, services text[], has_automation boolean
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
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           k.profession_recherchee, k.hebergement_offerte,
           k.rx_jour_semaine, k.rx_jour_weekend, k.seul_pharmacien,
           k.atp_presente, k.services, k.has_automation
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
       and (
         public.est_admin()
         or (
           not public.est_exclu(auth.uid(), k.pharmacie_id)
           and k.profession_recherchee = coalesce(
             (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien')
         )
       )
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- 3) get_contrat_fiche — reprend sql/52 tel quel (CTE base + reveler +
--    noms/réputation/favoris) + ajoute has_automation et lunch_coverage
--    à la fin des deux listes de colonnes (k.* dans le CTE les couvre
--    déjà automatiquement, rien d'autre à changer dans le corps).
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
  ma_candidature_statut text, est_ma_pharmacie boolean,
  profession_recherchee text,
  hebergement_offerte boolean, hebergement_adresse text,
  pharmacie_nom text, pharmacie_note_moyenne numeric, pharmacie_note_nombre bigint,
  pharmacien_nom text, pharmacien_note_moyenne numeric, pharmacien_note_nombre bigint,
  pharmacien_favoris_nombre bigint,
  has_automation boolean, lunch_coverage boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    with base as (
      select k.*, p.ville as p_ville, p.logiciel as p_logiciel, p.code_postal as p_code_postal,
             p.nom_pharmacie as p_nom_pharmacie,
             p.hebergement_adresse as p_hebergement_adresse,
             (select c.statut from public.candidatures c
               where c.contrat_id = k.id and c.pharmacien_id = auth.uid()) as ma_candidature_statut,
             (k.pharmacie_id = auth.uid()) as est_ma_pharmacie,
             (
               k.statut in ('attribue','complete')
               and (
                 k.pharmacie_id = auth.uid()
                 or public.est_admin()
                 or exists(select 1 from public.candidatures ca
                           where ca.contrat_id = k.id and ca.pharmacien_id = auth.uid()
                             and ca.statut = 'accepte')
               )
             ) as reveler,
             (select ca.pharmacien_id from public.candidatures ca
               where ca.contrat_id = k.id and ca.statut = 'accepte' limit 1) as v_pharmacien_id
        from public.contrats k
        join public.profiles p on p.id = k.pharmacie_id
       where k.numero_reference = upper(trim(p_ref))
         and (
           public.est_admin()
           or k.pharmacie_id = auth.uid()
           or (public.mon_role() = 'pharmacien'
               and (
                 (k.statut = 'ouvert'
                  and k.profession_recherchee = coalesce(
                    (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien'))
                 or public.a_postule(k.id)
               )
               and not public.est_exclu(auth.uid(), k.pharmacie_id))
         )
    )
    select b.id, b.numero_reference, b.date_contrat,
           b.heure_debut, b.heure_fin, b.tarif_horaire,
           b.rx_jour_semaine, b.rx_jour_weekend,
           b.seul_pharmacien, b.atp_presente, b.services,
           b.notes, b.statut, b.created_at,
           b.p_ville, b.p_logiciel, b.code_postal,
           b.ma_candidature_statut, b.est_ma_pharmacie,
           b.profession_recherchee,
           b.hebergement_offerte,
           case when b.reveler and b.hebergement_offerte then b.p_hebergement_adresse else null end,
           case when b.reveler
             then coalesce(nullif(b.p_nom_pharmacie,''), b.p_ville, 'Pharmacie')
             else null end,
           case when b.reveler
             then (select np.moyenne from public.get_note_profil(b.pharmacie_id) np)
             else null end,
           case when b.reveler
             then (select np.nombre from public.get_note_profil(b.pharmacie_id) np)
             else null end,
           case when b.reveler and b.v_pharmacien_id is not null then (
             select coalesce(nullif(trim(coalesce(pn.prenom,'')||' '||coalesce(pn.nom,'')),''), pn.courriel, 'Pharmacien(ne)')
               from public.profiles pn where pn.id = b.v_pharmacien_id
           ) else null end,
           case when b.reveler and b.v_pharmacien_id is not null
             then (select np.moyenne from public.get_note_profil(b.v_pharmacien_id) np)
             else null end,
           case when b.reveler and b.v_pharmacien_id is not null
             then (select np.nombre from public.get_note_profil(b.v_pharmacien_id) np)
             else null end,
           case when b.reveler and b.v_pharmacien_id is not null
             then (select count(*) from public.favoris_pharmaciens fp where fp.pharmacien_id = b.v_pharmacien_id)
             else null end,
           b.has_automation, b.lunch_coverage
      from base b;
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification rapide après exécution :
--   select has_automation, lunch_coverage from public.contrats limit 1;
--   -- puis recharger contrats.html et contrat.html : rien ne doit
--   -- changer visuellement tant que le front-end n'est pas mis à jour
--   -- (colonnes nouvelles, valeurs par défaut false/null, non lues encore).
-- ---------------------------------------------------------------------
