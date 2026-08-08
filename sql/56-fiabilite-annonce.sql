-- =====================================================================
-- C-DIRECT · SQL 56 — Feature 4 : Fiabilité de l'annonce
-- (le pharmacien note, après un contrat COMPLÉTÉ, si la réalité a
-- correspondu à ce qui était annoncé — distinct de l'évaluation générale
-- 1-5 déjà existante sur `evaluations`, par décision explicite de Robert.
-- Une seule direction : la pharmacie ne note pas "la fiabilité" de son
-- propre pharmacien, donc pas de auteur_role/cible_id comme sur
-- `evaluations` — toujours pharmacien -> pharmacie via le contrat.)
--
-- Suit le patron déjà en place sur evaluations.sql (sql/19) : la table
-- n'a QUE une politique SELECT (l'auteur lit ses propres lignes) ; toute
-- écriture passe par une fonction security definer qui revalide l'accès
-- elle-même — jamais d'insert direct depuis le client.
--
-- IMPORTANT : get_contrats_ouverts()/get_contrat_fiche() repartent du
-- corps exact de sql/54 (liste) et **sql/55** (fiche, DÉJÀ CORRIGÉ —
-- b.p_code_postal, pas b.code_postal) — vérifié colonne par colonne,
-- position par position, contre RETURNS TABLE avant d'écrire ce fichier,
-- après le bug trouvé en direct la dernière fois.
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Table + RLS
-- ---------------------------------------------------------------------
create table if not exists public.fiabilite_annonce (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  note_precision smallint not null check (note_precision between 1 and 5),
  volume_conforme boolean,
  personnel_conforme boolean,
  commentaire text check (char_length(commentaire) <= 1000),
  created_at timestamptz not null default now(),
  unique (contrat_id, pharmacien_id)
);
create index if not exists idx_fiabilite_contrat on public.fiabilite_annonce(contrat_id);

alter table public.fiabilite_annonce enable row level security;
drop policy if exists "fiabilite_lecture_propre" on public.fiabilite_annonce;
create policy "fiabilite_lecture_propre" on public.fiabilite_annonce for select
  using (pharmacien_id = auth.uid());

-- ---------------------------------------------------------------------
-- 2) Soumettre (ou modifier) son avis de fiabilité pour un contrat.
--    Exige : contrat COMPLÉTÉ + candidature acceptée de l'appelant.
-- ---------------------------------------------------------------------
create or replace function public.soumettre_fiabilite(
  p_contrat uuid, p_note_precision int, p_volume_conforme boolean,
  p_personnel_conforme boolean, p_commentaire text
) returns void language plpgsql security definer set search_path = public as $$
declare v_ok boolean;
begin
  if p_note_precision is null or p_note_precision < 1 or p_note_precision > 5 then
    raise exception 'Note invalide (1 à 5).';
  end if;

  select true into v_ok
    from public.contrats k
   where k.id = p_contrat
     and k.statut = 'complete'
     and exists (select 1 from public.candidatures c
                 where c.contrat_id = k.id and c.pharmacien_id = auth.uid()
                   and c.statut = 'accepte');
  if v_ok is null then
    raise exception 'Contrat introuvable, non complété, ou accès refusé.';
  end if;

  insert into public.fiabilite_annonce
    (contrat_id, pharmacien_id, note_precision, volume_conforme, personnel_conforme, commentaire)
  values
    (p_contrat, auth.uid(), p_note_precision, p_volume_conforme, p_personnel_conforme, nullif(btrim(p_commentaire),''))
  on conflict (contrat_id, pharmacien_id) do update
    set note_precision = excluded.note_precision,
        volume_conforme = excluded.volume_conforme,
        personnel_conforme = excluded.personnel_conforme,
        commentaire = excluded.commentaire,
        created_at = now();
end; $$;
grant execute on function public.soumettre_fiabilite(uuid,int,boolean,boolean,text) to authenticated;

-- ---------------------------------------------------------------------
-- 3) Contrats que l'appelant (pharmacien) doit encore noter.
-- ---------------------------------------------------------------------
create or replace function public.get_fiabilite_a_faire()
returns table (contrat_id uuid, numero_reference text, date_contrat date, pharmacie_nom text)
language sql stable security definer set search_path = public as $$
  select k.id, k.numero_reference, k.date_contrat,
         coalesce(nullif(p.nom_pharmacie,''), p.ville, 'Pharmacie')
    from public.contrats k
    join public.profiles p on p.id = k.pharmacie_id
   where k.statut = 'complete'
     and exists (select 1 from public.candidatures c
                 where c.contrat_id = k.id and c.pharmacien_id = auth.uid()
                   and c.statut = 'accepte')
     and not exists (select 1 from public.fiabilite_annonce f
                     where f.contrat_id = k.id and f.pharmacien_id = auth.uid())
   order by k.date_contrat desc;
$$;
grant execute on function public.get_fiabilite_a_faire() to authenticated;

-- ---------------------------------------------------------------------
-- 4) Score agrégé d'une pharmacie — masqué tant qu'il y a moins de 3 avis
--    (having, donc AUCUNE ligne retournée sous le seuil, jamais un score
--    basé sur 1-2 avis qui définirait injustement une pharmacie).
-- ---------------------------------------------------------------------
create or replace function public.get_fiabilite_pharmacie(p_pharmacie_id uuid)
returns table (note_moyenne numeric, nb_avis bigint, taux_volume_conforme numeric, taux_personnel_conforme numeric)
language sql stable security definer set search_path = public as $$
  select round(avg(f.note_precision), 2),
         count(*),
         round(100.0 * count(*) filter (where f.volume_conforme) / nullif(count(*) filter (where f.volume_conforme is not null), 0), 0),
         round(100.0 * count(*) filter (where f.personnel_conforme) / nullif(count(*) filter (where f.personnel_conforme is not null), 0), 0)
    from public.fiabilite_annonce f
    join public.contrats k on k.id = f.contrat_id
   where k.pharmacie_id = p_pharmacie_id
  having count(*) >= 3;
$$;
grant execute on function public.get_fiabilite_pharmacie(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 5) get_contrats_ouverts — reprend sql/54 tel quel + badge fiabilité
--    (left join lateral : NULL si sous le seuil de 3 avis, jamais caché
--    "à moitié", le front-end masque simplement le badge si null).
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean,
  profession_recherchee text, hebergement_offerte boolean,
  rx_jour_semaine int, rx_jour_weekend int, seul_pharmacien boolean,
  atp_presente boolean, services text[], has_automation boolean,
  fiabilite_note numeric, fiabilite_nb bigint
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
           k.atp_presente, k.services, k.has_automation,
           fp.note_moyenne, fp.nb_avis
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
      left join lateral public.get_fiabilite_pharmacie(k.pharmacie_id) fp on true
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
-- 6) get_contrat_fiche — reprend sql/55 tel quel (déjà corrigé) + badge
--    fiabilité. Vérifié colonne-par-colonne : RETURNS TABLE et le SELECT
--    final ont chacun 33 colonnes, dans le même ordre.
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
  has_automation boolean, lunch_coverage boolean,
  fiabilite_note numeric, fiabilite_nb bigint
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
               where ca.contrat_id = k.id and ca.statut = 'accepte' limit 1) as v_pharmacien_id,
             fp.note_moyenne as fp_note_moyenne, fp.nb_avis as fp_nb_avis
        from public.contrats k
        join public.profiles p on p.id = k.pharmacie_id
        left join lateral public.get_fiabilite_pharmacie(k.pharmacie_id) fp on true
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
           b.p_ville, b.p_logiciel, b.p_code_postal,
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
             then (select count(*) from public.favoris_pharmaciens fp2 where fp2.pharmacien_id = b.v_pharmacien_id)
             else null end,
           b.has_automation, b.lunch_coverage,
           b.fp_note_moyenne, b.fp_nb_avis
      from base b;
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution : ouvrir n'importe quel contrat doit
-- toujours fonctionner (pas de régression sur sql/55). Le badge fiabilité
-- n'apparaîtra qu'une fois 3 avis soumis pour une même pharmacie — normal
-- de voir "null"/rien au début, aucune pharmacie n'a encore 3 avis.
-- ---------------------------------------------------------------------
