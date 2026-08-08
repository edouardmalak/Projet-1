-- =====================================================================
-- C-DIRECT · SQL 57 — Feature 3 : Accès prioritaire (Trusted-Pool)
--
-- Une pharmacie peut publier un contrat en l'offrant D'ABORD à ses
-- pharmaciens favoris (table `favoris_pharmaciens`, sql/35 — déjà
-- utilisée pour l'Instant Booking ; PAS de nouvelle table de confiance,
-- décision explicite de Robert : une seule liste sert les deux usages).
--
-- Mécanique : pendant la fenêtre (acces_prioritaire = true ET
-- now() < acces_prioritaire_jusqu_a), le contrat est INVISIBLE pour tout
-- pharmacien qui n'est pas dans favoris_pharmaciens de cette pharmacie —
-- même traitement que les paires bloquées (est_exclu) : pas d'aperçu
-- partiel, pas de fiche "bientôt disponible", juste invisible, exactement
-- comme le reste du réseau ne voit pas les contrats d'une pharmacie qui
-- l'a bloqué. Une fois la fenêtre expirée, le contrat rejoint le bassin
-- général normalement (aucune ligne à modifier — c'est une comparaison
-- de date évaluée à chaque appel, pas un état stocké).
--
-- Diffusion SMS/push : DÉLIBÉRÉMENT non modifiée dans cette passe — si
-- acces_prioritaire est activé, espace-pharmacie.html n'appelle PAS
-- cdDiffuserContrat() à la publication (voir ce fichier JS), pour éviter
-- d'envoyer un texto/push vers un lien qui serait invisible pour la
-- majorité des destinataires. Conséquence assumée : les pharmaciens
-- favoris doivent consulter le tableau (où le badge les avertit) plutôt
-- que recevoir une alerte immédiate, et une fois la fenêtre expirée, le
-- contrat ne déclenche PAS de diffusion générale rétroactive — même
-- traitement qu'un contrat qui reste ouvert sans nouvelle relance.
-- Un futur cron qui déclencherait la diffusion générale exactement à
-- l'expiration de la fenêtre est possible mais PAS construit ici
-- (préféré : livrer le mécanisme de base sans toucher au Worker SMS,
-- historiquement la zone la plus fragile de ce projet) — à signaler à
-- Robert comme amélioration future, pas oubliée en silence.
--
-- IMPORTANT : get_contrats_ouverts()/get_contrat_fiche() repartent du
-- corps EXACT de sql/56 (déjà en production) — vérifié colonne par
-- colonne, position par position, contre RETURNS TABLE avant d'écrire ce
-- fichier (22 colonnes pour la liste, 34 pour la fiche), même discipline
-- que sql/56 après les bugs sql/50 (id ambigu) et sql/52 (b.code_postal).
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Colonnes contrats
-- ---------------------------------------------------------------------
alter table public.contrats add column if not exists acces_prioritaire boolean not null default false;
alter table public.contrats add column if not exists acces_prioritaire_jusqu_a timestamptz;

alter table public.contrats drop constraint if exists contrats_acces_prioritaire_coherent;
alter table public.contrats add constraint contrats_acces_prioritaire_coherent
  check (not acces_prioritaire or acces_prioritaire_jusqu_a is not null);

-- ---------------------------------------------------------------------
-- 2) get_contrats_ouverts — reprend sql/56 tel quel + gate accès prioritaire
--    + colonne acces_prioritaire_actif (calculée, jamais stockée).
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
  fiabilite_note numeric, fiabilite_nb bigint,
  acces_prioritaire_actif boolean
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
           fp.note_moyenne, fp.nb_avis,
           (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a)
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
           and (
             not (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a)
             or exists (select 1 from public.favoris_pharmaciens tf
                         where tf.pharmacie_id = k.pharmacie_id and tf.pharmacien_id = auth.uid())
           )
         )
       )
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- 3) get_contrat_fiche — reprend sql/56 tel quel + même gate, appliqué
--    uniquement à la branche "contrat ouvert" (une candidature déjà
--    déposée, ou le statut attribué/complété, restent visibles sans
--    condition — le gate ne concerne que la découverte d'un contrat
--    encore ouvert). Vérifié : RETURNS TABLE et le SELECT final ont
--    chacun 34 colonnes, dans le même ordre.
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
  fiabilite_note numeric, fiabilite_nb bigint,
  acces_prioritaire_actif boolean
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
                    (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien')
                  and (
                    not (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a)
                    or exists (select 1 from public.favoris_pharmaciens tf
                                where tf.pharmacie_id = k.pharmacie_id and tf.pharmacien_id = auth.uid())
                  ))
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
           b.fp_note_moyenne, b.fp_nb_avis,
           (b.acces_prioritaire and b.acces_prioritaire_jusqu_a is not null and now() < b.acces_prioritaire_jusqu_a)
      from base b;
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution : ouvrir n'importe quel contrat existant
-- doit toujours fonctionner (pas de régression sur sql/56). Un contrat
-- SANS acces_prioritaire n'est jamais affecté par ce fichier (le gate
-- se réduit toujours à `true` quand acces_prioritaire = false).
-- ---------------------------------------------------------------------
