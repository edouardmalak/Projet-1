-- =====================================================================
-- C-DIRECT · SQL 41 — Nom, note (⭐) et nombre de favoris affichés à
-- côté du nom des DEUX parties, sur la fiche du mandat et dans l'en-tête
-- du clavardage. À exécuter dans Supabase → SQL Editor.
--
-- RÈGLE DE VIE PRIVÉE CONSERVÉE : sur get_contrat_fiche, l'identité et la
-- réputation des deux parties ne sont révélées QUE lorsque le contrat est
-- CONFIRMÉ (attribué/complété) et pour les parties elles-mêmes (ou
-- l'admin) — exactement la même règle que la messagerie (sql/18/23) et
-- l'évaluation (sql/19). Avant confirmation, tout reste anonyme comme
-- aujourd'hui : on ne change rien à ce mécanisme, on ajoute seulement de
-- l'info dans la fenêtre où elle s'ouvrait déjà.
-- Sur mes_fils(), aucune règle à ajouter : un fil n'existe déjà que pour
-- une relation confirmée des deux côtés.
-- Le compteur de favoris n'existe que dans un sens (pharmacie → pharmaciens,
-- sql/35) : il n'est donc renvoyé que pour un pharmacien, jamais pour une
-- pharmacie (ce concept n'existe pas dans l'autre sens).
-- =====================================================================

-- ---------------------------------------------------------------------
-- get_contrat_fiche : + nom/note des deux parties, + favoris du pharmacien
-- ---------------------------------------------------------------------
drop function if exists public.get_contrat_fiche(text);
create function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text,
  ma_candidature_statut text, est_ma_pharmacie boolean,
  pharmacie_nom text, pharmacie_note_moyenne numeric, pharmacie_note_nombre bigint,
  pharmacien_nom text, pharmacien_note_moyenne numeric, pharmacien_note_nombre bigint,
  pharmacien_favoris_nombre bigint
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    with base as (
      select k.*, p.ville as p_ville, p.logiciel as p_logiciel,
             p.nom_pharmacie as p_nom_pharmacie,
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
               and (k.statut = 'ouvert' or public.a_postule(k.id)))
         )
    )
    select b.id, b.numero_reference, b.date_contrat,
           b.heure_debut, b.heure_fin, b.tarif_horaire,
           b.rx_jour_semaine, b.rx_jour_weekend,
           b.seul_pharmacien, b.atp_presente, b.services,
           b.notes, b.statut, b.created_at,
           b.p_ville, b.p_logiciel,
           b.ma_candidature_statut, b.est_ma_pharmacie,
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
-- mes_fils : + note/favoris de la contrepartie (relation déjà confirmée)
-- ---------------------------------------------------------------------
drop function if exists public.mes_fils();
create function public.mes_fils()
returns table (
  fil_id uuid, statut text,
  cloture_pharmacie boolean, cloture_pharmacien boolean,
  contrepartie_nom text, contrat_ref text,
  dernier_message text, dernier_le timestamptz, nb_messages bigint,
  contrepartie_note_moyenne numeric, contrepartie_note_nombre bigint,
  contrepartie_favoris_nombre bigint
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select f.id, f.statut, f.cloture_pharmacie, f.cloture_pharmacien,
           case when auth.uid() = f.pharmacie_id
                then nullif(trim(coalesce(pn.prenom,'')||' '||coalesce(pn.nom,'')),'')
                else coalesce(nullif(pe.nom_pharmacie,''),
                              nullif(trim(coalesce(pe.prenom,'')||' '||coalesce(pe.nom,'')),''))
           end,
           k.numero_reference,
           (select m.corps from public.messages m
             where m.fil_id = f.id order by m.created_at desc limit 1),
           (select m.created_at from public.messages m
             where m.fil_id = f.id order by m.created_at desc limit 1),
           (select count(*) from public.messages m where m.fil_id = f.id),
           (select np.moyenne from public.get_note_profil(
              case when auth.uid() = f.pharmacie_id then f.pharmacien_id else f.pharmacie_id end) np),
           (select np.nombre from public.get_note_profil(
              case when auth.uid() = f.pharmacie_id then f.pharmacien_id else f.pharmacie_id end) np),
           case when auth.uid() = f.pharmacie_id
             then (select count(*) from public.favoris_pharmaciens fp where fp.pharmacien_id = f.pharmacien_id)
             else null end
      from public.fils f
      join public.profiles pe on pe.id = f.pharmacie_id
      join public.profiles pn on pn.id = f.pharmacien_id
      left join public.contrats k on k.id = f.contrat_id
     where auth.uid() in (f.pharmacie_id, f.pharmacien_id)
     order by f.statut, coalesce(
       (select max(m.created_at) from public.messages m where m.fil_id = f.id),
       f.created_at) desc;
end;
$$;
revoke all on function public.mes_fils() from public, anon;
grant execute on function public.mes_fils() to authenticated;
