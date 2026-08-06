-- =====================================================================
-- C-DIRECT · SQL 52 — HÉBERGEMENT EN NATURE (offert par la pharmacie)
-- À exécuter dans Supabase → SQL Editor, APRÈS 51-fix-id-ambiguous.sql.
--
-- Nouveau concept, distinct de l'indemnité cash existante : la pharmacie
-- peut offrir un vrai logement (adresse) pour un contrat donné, au lieu de
-- verser l'indemnité d'hébergement de 250 $/jour (regles_reseau.hebergement_jour,
-- déclenchée automatiquement dès ≥100 km aller simple, sql/05). Quand le
-- logement en nature est offert, AUCUNE indemnité cash ne doit s'ajouter au
-- mandat/à la facture pour ce contrat — la case cash et la case nature sont
-- mutuellement exclusives.
--
-- Le pharmacien peut aussi, à l'inverse, DEMANDER explicitement l'indemnité
-- cash standard en postulant (« Postuler avec modification »), même si la
-- distance ne l'aurait pas déclenchée automatiquement.
--
-- Vie privée : l'adresse exacte suit EXACTEMENT la même règle que le nom des
-- parties (sql/41) — jamais visible avant confirmation du contrat, seulement
-- au pharmacien retenu (ou à la pharmacie elle-même / admin) une fois
-- attribué/complété. Le simple FAIT qu'un hébergement est offert (sans
-- adresse) reste lui visible dès la liste ouverte, pour que le pharmacien
-- puisse en tenir compte avant de postuler.
--
-- IMPORTANT (trouvé en préparant cette migration) : sql/50 a reconstruit
-- get_contrat_fiche() pour le filtre profession et a, par erreur, laissé
-- tomber les colonnes pharmacie_nom/pharmacien_nom/notes/favoris ajoutées
-- par sql/41 — cassant silencieusement le bloc « nom + réputation » de
-- contrat.html sur tout contrat confirmé depuis sql/50 (aucune erreur
-- visible : les colonnes manquantes se traduisent juste par des valeurs
-- undefined côté JS, donc le bloc ne s'affichait plus jamais). Cette
-- migration restaure ces colonnes en même temps qu'elle ajoute
-- l'hébergement, puisque la fonction doit de toute façon être reconstruite.
--
-- Idempotent (add column if not exists / drop-then-create).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Colonnes
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists hebergement_adresse text;   -- pharmacie : adresse standard, remplie une fois

alter table public.contrats
  add column if not exists hebergement_offerte boolean not null default false;  -- bascule par contrat, posée à la publication

alter table public.candidatures
  add column if not exists demande_hebergement boolean not null default false; -- demande du pharmacien à l'offre (indemnité cash)

-- ---------------------------------------------------------------------
-- 2) appliquer_indemnites — priorité : nature offerte > demande cash
--    explicite > comportement existant (distance ≥ seuil). Nouveau 3e
--    paramètre optionnel (défaut null) = rétrocompatible avec tout appelant
--    qui ne le passe pas encore ; les 3 appelants de ce projet sont mis à
--    jour ci-dessous pour le passer.
-- ---------------------------------------------------------------------
drop function if exists public.appliquer_indemnites(uuid, numeric);
create or replace function public.appliquer_indemnites(p_contrat uuid, p_distance numeric, p_candidature uuid default null)
returns void language plpgsql security definer set search_path = public
as $$
declare r public.regles_reseau%rowtype;
        v_offerte boolean;
        v_demandee boolean := false;
begin
  select * into r from public.regles_reseau where id = 1;
  select coalesce(k.hebergement_offerte, false) into v_offerte
    from public.contrats k where k.id = p_contrat;

  if p_candidature is not null then
    select coalesce(c.demande_hebergement, false) into v_demandee
      from public.candidatures c where c.id = p_candidature;
  end if;

  update public.contrats
     set per_diem    = coalesce(p_distance >= r.seuil_per_diem_km, false),
         hebergement = case
                          when v_offerte  then false   -- logement fourni : jamais de cash en plus
                          when v_demandee then true     -- demande explicite du pharmacien à l'offre
                          else coalesce(p_distance >= r.seuil_hebergement_km, false)
                       end
   where id = p_contrat;
end;
$$;

-- ---------------------------------------------------------------------
-- 3) Les 3 appelants — même signature (uuid), corps modifié seulement pour
--    passer p_candidature (déjà en portée dans chacun).
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
  perform public.appliquer_indemnites(v_contrat, v_distance, p_candidature);
end;
$$;
revoke all on function public.accepter_candidature(uuid) from public, anon;
grant execute on function public.accepter_candidature(uuid) to authenticated;

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
  perform public.appliquer_indemnites(v_contrat, v_distance, p_candidature);
end;
$$;
revoke all on function public.accepter_contre_offre(uuid) from public, anon;
grant execute on function public.accepter_contre_offre(uuid) to authenticated;

-- accepter_candidature_auto (sql/36, Instant Booking) — même correctif,
-- corps repris tel quel sinon (service_role only, inchangé).
create or replace function public.accepter_candidature_auto(p_candidature uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_contrat uuid; v_distance numeric;
begin
  select c.contrat_id, c.distance_km into v_contrat, v_distance
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
   where c.id = p_candidature
     and k.statut = 'ouvert'
     and c.statut in ('propose','contre_offre');
  if v_contrat is null then
    raise exception 'Candidature introuvable ou contrat non ouvert';
  end if;

  update public.candidatures
     set statut = 'accepte',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','accepte','par','pharmacie','auto',true,'motif','instant_booking'))
   where id = p_candidature;

  update public.candidatures
     set statut = 'refuse',
         message = public.ajouter_jalon(message, jsonb_build_object(
           'etape','refuse','par','pharmacie','auto',true))
   where contrat_id = v_contrat and id <> p_candidature
     and statut in ('propose','contre_offre');

  update public.contrats set statut = 'attribue' where id = v_contrat;
  perform public.appliquer_indemnites(v_contrat, v_distance, p_candidature);
end;
$$;
revoke all on function public.accepter_candidature_auto(uuid) from public, anon, authenticated;
grant execute on function public.accepter_candidature_auto(uuid) to service_role;

-- ---------------------------------------------------------------------
-- 4) get_contrats_ouverts — + hebergement_offerte (fait visible dès la
--    liste ouverte, jamais l'adresse). Reprend sql/51 tel quel sinon.
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean,
  profession_recherchee text, hebergement_offerte boolean
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
           k.profession_recherchee, k.hebergement_offerte
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
-- 5) get_contrat_fiche — restaure pharmacie_nom/pharmacien_nom/notes/
--    favoris (sql/41, échappés de sql/50 par erreur) + garde le correctif
--    d'aliasing de sql/51 + ajoute hebergement_offerte (toujours visible)
--    et hebergement_adresse (gaté par "reveler", même règle que les noms).
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
  pharmacien_favoris_nombre bigint
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
             else null end
      from base b;
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification rapide après exécution :
--   select column_name from information_schema.columns
--    where table_name='contrats' and column_name='hebergement_offerte';
--   -- puis recharger un contrat confirmé dans contrat.html : le bloc
--   -- nom+réputation doit réapparaître (régression sql/50 corrigée).
-- ---------------------------------------------------------------------
