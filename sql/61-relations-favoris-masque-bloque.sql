-- =====================================================================
-- C-DIRECT · SQL 61 — Relations locum <-> pharmacie en libre-service :
-- favori(te) / masqué(e) / bloqué(e), dans les DEUX sens.
--
-- Ne duplique PAS ce qui existe déjà :
--   - pharmacie -> pharmacien : la table favoris_pharmaciens (sql/35) sert
--     déjà de bassin de confiance (accès prioritaire, sql/57 ; Instant
--     Booking, sql/36). On lui AJOUTE une colonne `state` au lieu de créer
--     une deuxième table — exactement l'instruction du dossier de refonte
--     ("this absorbs the standalone trusted_locums table... single
--     relationship table per direction"). Toute ligne existante devient
--     'trusted' par défaut : comportement 100% inchangé pour l'existant.
--   - locum -> pharmacie : rien n'existe encore de ce côté (le seul
--     `favoris` existant, sql/02, sauvegarde des CONTRATS, pas des
--     pharmacies — concept différent, non touché). Nouvelle table
--     locum_pharmacy_relations.
--   - Le blocage MUTUEL décidé par un admin (table exclusions, sql/21,
--     fonction est_exclu()) reste tel quel, pour les litiges — c'est un
--     outil séparé. Les nouveaux blocages LIBRE-SERVICE s'ajoutent en
--     UNION avec est_exclu() à chaque endroit qui filtrait déjà dessus :
--     un pharmacien invisible à cause d'un blocage libre-service l'est
--     exactement de la même façon qu'à cause d'un blocage admin.
--
-- États, mutuellement exclusifs par paire (une seule ligne par paire) :
--   locum_pharmacy_relations.state   : 'favorite' | 'muted' | 'blocked'
--   favoris_pharmaciens.state        : 'trusted'  | 'muted' | 'blocked'
--   (valeur par défaut 'trusted' pour les lignes déjà existantes)
--
-- Portée du blocage libre-service, identique au blocage admin existant
-- (est_exclu) — pas plus, pas moins, pour rester cohérent avec ce qui
-- est déjà en place : bloque la DÉCOUVERTE (contrats invisibles) et la
-- CRÉATION d'un nouveau fil de messagerie (ouvrir_fil). Un fil déjà
-- ouvert avant le blocage n'est pas coupé rétroactivement — même limite
-- que le blocage admin aujourd'hui, jamais signalée comme un problème ;
-- à durcir plus tard si Robert le souhaite, pas fait ici en silence.
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) locum -> pharmacie (nouvelle table)
-- ---------------------------------------------------------------------
create table if not exists public.locum_pharmacy_relations (
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  pharmacie_id  uuid not null references public.profiles(id) on delete cascade,
  state         text not null check (state in ('favorite','muted','blocked')),
  created_at    timestamptz not null default now(),
  primary key (pharmacien_id, pharmacie_id)
);
create index if not exists idx_lpr_pharmacie on public.locum_pharmacy_relations(pharmacie_id);

alter table public.locum_pharmacy_relations enable row level security;

-- Le pharmacien gère sa propre liste. La pharmacie n'a PAS d'accès direct à
-- cette table (même un "muted" ou "blocked" doit rester invisible pour
-- elle — "silent", comme demandé) ; tout ce dont elle a besoin passe par
-- les fonctions security definer ci-dessous (mutuellement_favori, etc.).
drop policy if exists lpr_gestion on public.locum_pharmacy_relations;
create policy lpr_gestion on public.locum_pharmacy_relations
  for all using (auth.uid() = pharmacien_id) with check (auth.uid() = pharmacien_id);

-- ---------------------------------------------------------------------
-- 2) pharmacie -> pharmacien (extension de favoris_pharmaciens, sql/35)
-- ---------------------------------------------------------------------
alter table public.favoris_pharmaciens
  add column if not exists state text not null default 'trusted'
    check (state in ('trusted','muted','blocked'));

-- ---------------------------------------------------------------------
-- 3) Helpers
-- ---------------------------------------------------------------------

-- La paire est-elle bloquée, par blocage ADMIN (sql/21) OU libre-service
-- (l'une ou l'autre direction) ? Point d'entrée unique réutilisé partout
-- ci-dessous pour ne jamais avoir à répéter/oublier une des trois sources.
create or replace function public.est_bloque(p_pharmacien uuid, p_pharmacie uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.est_exclu(p_pharmacien, p_pharmacie)
    or exists (select 1 from public.favoris_pharmaciens f
                where f.pharmacie_id = p_pharmacie and f.pharmacien_id = p_pharmacien and f.state = 'blocked')
    or exists (select 1 from public.locum_pharmacy_relations l
                where l.pharmacie_id = p_pharmacie and l.pharmacien_id = p_pharmacien and l.state = 'blocked');
$$;
revoke all on function public.est_bloque(uuid, uuid) from public, anon;
grant execute on function public.est_bloque(uuid, uuid) to authenticated;

-- Favori mutuel : le pharmacien a mis cette pharmacie en préférée ET la
-- pharmacie a mis ce pharmacien en confiance. Sert le badge "mutuellement
-- favoris" des deux côtés.
create or replace function public.mutuellement_favori(p_pharmacien uuid, p_pharmacie uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.locum_pharmacy_relations l
                  where l.pharmacien_id = p_pharmacien and l.pharmacie_id = p_pharmacie and l.state = 'favorite')
     and exists (select 1 from public.favoris_pharmaciens f
                  where f.pharmacien_id = p_pharmacien and f.pharmacie_id = p_pharmacie and f.state = 'trusted');
$$;
revoke all on function public.mutuellement_favori(uuid, uuid) from public, anon;
grant execute on function public.mutuellement_favori(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 4) definir_relation_* — pose ou efface la relation (une seule ligne par
--    paire : poser un nouvel état remplace l'ancien, jamais deux lignes).
--    p_etat = null efface la relation (retour à "neutre").
-- ---------------------------------------------------------------------
create or replace function public.definir_relation_locum(p_pharmacie uuid, p_etat text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacien' then raise exception 'Accès refusé'; end if;
  if p_etat is null then
    delete from public.locum_pharmacy_relations where pharmacien_id = auth.uid() and pharmacie_id = p_pharmacie;
    return;
  end if;
  if p_etat not in ('favorite','muted','blocked') then raise exception 'État invalide'; end if;
  insert into public.locum_pharmacy_relations (pharmacien_id, pharmacie_id, state)
  values (auth.uid(), p_pharmacie, p_etat)
  on conflict (pharmacien_id, pharmacie_id) do update set state = excluded.state;
end;
$$;
revoke all on function public.definir_relation_locum(uuid, text) from public, anon;
grant execute on function public.definir_relation_locum(uuid, text) to authenticated;

create or replace function public.definir_relation_pharmacie(p_pharmacien uuid, p_etat text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacie' then raise exception 'Accès refusé'; end if;
  if p_etat is null then
    delete from public.favoris_pharmaciens where pharmacie_id = auth.uid() and pharmacien_id = p_pharmacien;
    return;
  end if;
  if p_etat not in ('trusted','muted','blocked') then raise exception 'État invalide'; end if;
  insert into public.favoris_pharmaciens (pharmacie_id, pharmacien_id, state)
  values (auth.uid(), p_pharmacien, p_etat)
  on conflict (pharmacie_id, pharmacien_id) do update set state = excluded.state;
end;
$$;
revoke all on function public.definir_relation_pharmacie(uuid, text) from public, anon;
grant execute on function public.definir_relation_pharmacie(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 5) lister_relations_* — pour les listes "préférées / masquées /
--    bloquées" (top menu + Paramètres). Security definer, bornées à
--    auth.uid(), même discipline que lister_pharmaciens_deja_postules
--    (sql/59) : c'est le SEUL moyen pour une pharmacie de lire un nom de
--    pharmacien hors RLS, et seulement pour ceux qu'elle a déjà en
--    relation — aucune fuite d'identité nouvelle.
-- ---------------------------------------------------------------------
create or replace function public.lister_relations_locum()
returns table (pharmacie_id uuid, nom_pharmacie text, ville text, state text, note_moyenne numeric, note_nombre bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacien' then raise exception 'Accès refusé'; end if;
  return query
    select p.id, coalesce(nullif(p.nom_pharmacie,''), p.ville, 'Pharmacie'), p.ville, l.state,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.locum_pharmacy_relations l
      join public.profiles p on p.id = l.pharmacie_id
     where l.pharmacien_id = auth.uid()
     order by l.state, nom_pharmacie;
end;
$$;
revoke all on function public.lister_relations_locum() from public, anon;
grant execute on function public.lister_relations_locum() to authenticated;

create or replace function public.lister_relations_pharmacie()
returns table (pharmacien_id uuid, nom text, prenom text, ville_base text, state text, note_moyenne numeric, note_nombre bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if public.mon_role() <> 'pharmacie' then raise exception 'Accès refusé'; end if;
  return query
    select p.id, p.nom, p.prenom, p.ville_base, f.state,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.favoris_pharmaciens f
      join public.profiles p on p.id = f.pharmacien_id
     where f.pharmacie_id = auth.uid()
     order by f.state, prenom, nom;
end;
$$;
revoke all on function public.lister_relations_pharmacie() from public, anon;
grant execute on function public.lister_relations_pharmacie() to authenticated;

-- ---------------------------------------------------------------------
-- 6) get_contrats_ouverts — reprend sql/57 tel quel (22 colonnes, même
--    ordre) + ajoute : exclusion si blocage libre-service (l'une ou
--    l'autre direction) en plus de est_exclu ; gate accès prioritaire
--    étendu à state='trusted' (au lieu de la simple existence — une
--    ligne "muted"/"blocked" ne doit plus jamais valoir accès anticipé) ;
--    colonne mutuellement_favori_actif en plus, pour le badge.
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
  acces_prioritaire_actif boolean, mutuellement_favori_actif boolean
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
           (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a),
           public.mutuellement_favori(auth.uid(), k.pharmacie_id)
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
      left join lateral public.get_fiabilite_pharmacie(k.pharmacie_id) fp on true
     where k.statut = 'ouvert'
       and (
         public.est_admin()
         or (
           not public.est_bloque(auth.uid(), k.pharmacie_id)
           and k.profession_recherchee = coalesce(
             (select pr.profession from public.profiles pr where pr.id = auth.uid()), 'pharmacien')
           and (
             not (k.acces_prioritaire and k.acces_prioritaire_jusqu_a is not null and now() < k.acces_prioritaire_jusqu_a)
             or exists (select 1 from public.favoris_pharmaciens tf
                         where tf.pharmacie_id = k.pharmacie_id and tf.pharmacien_id = auth.uid() and tf.state = 'trusted')
           )
         )
       )
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- 7) get_contrat_fiche — reprend sql/57 tel quel (34 colonnes, même
--    ordre) + les mêmes deux ajustements (est_bloque, state='trusted'),
--    + mutuellement_favori_actif en 35e colonne.
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
  acces_prioritaire_actif boolean, mutuellement_favori_actif boolean
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
                                where tf.pharmacie_id = k.pharmacie_id and tf.pharmacien_id = auth.uid() and tf.state = 'trusted')
                  ))
                 or public.a_postule(k.id)
               )
               and not public.est_bloque(auth.uid(), k.pharmacie_id))
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
             then (select count(*) from public.favoris_pharmaciens fp2 where fp2.pharmacien_id = b.v_pharmacien_id and fp2.state = 'trusted')
             else null end,
           b.has_automation, b.lunch_coverage,
           b.fp_note_moyenne, b.fp_nb_avis,
           (b.acces_prioritaire and b.acces_prioritaire_jusqu_a is not null and now() < b.acces_prioritaire_jusqu_a),
           public.mutuellement_favori(auth.uid(), b.pharmacie_id)
      from base b;
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- 8) lister_pharmaciens_deja_postules — reprend sql/59 tel quel, ajoute
--    l'exclusion des pharmaciens déjà masqués/bloqués (n'a plus de sens
--    de proposer d'ajouter en confiance quelqu'un déjà masqué/bloqué) et
--    précise deja_favori sur state='trusted' spécifiquement.
-- ---------------------------------------------------------------------
create or replace function public.lister_pharmaciens_deja_postules()
returns table (
  pharmacien_id uuid, nom text, prenom text, ville_base text,
  note_moyenne numeric, note_nombre bigint, deja_favori boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select distinct p.id, p.nom, p.prenom, p.ville_base,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g),
           exists(select 1 from public.favoris_pharmaciens f
                   where f.pharmacie_id = auth.uid() and f.pharmacien_id = p.id and f.state = 'trusted')
      from public.candidatures c
      join public.contrats  k on k.id = c.contrat_id
      join public.profiles  p on p.id = c.pharmacien_id
     where k.pharmacie_id = auth.uid()
       and not public.est_bloque(c.pharmacien_id, k.pharmacie_id)
       and not exists (select 1 from public.favoris_pharmaciens f2
                         where f2.pharmacie_id = auth.uid() and f2.pharmacien_id = p.id and f2.state in ('muted','blocked'))
     order by 3, 2; -- prenom, nom
end;
$$;
revoke all on function public.lister_pharmaciens_deja_postules() from public, anon;
grant execute on function public.lister_pharmaciens_deja_postules() to authenticated;

-- ---------------------------------------------------------------------
-- 9) accepter_candidature_auto — DÉLIBÉRÉMENT NON TOUCHÉE ICI.
--
--    Découverte en exécutant ce fichier (2026-08-08) : la version LIVE de
--    cette fonction a dérivé de ce que montre sql/36 dans le repo.
--    pg_get_functiondef() en production donne : RETURNS void (pas
--    boolean), ET son corps ne vérifie plus DU TOUT type_candidature
--    ='instantanee', ni confirmation_auto_favoris, ni favoris_pharmaciens,
--    ni une exclusion — elle accepte automatiquement toute candidature
--    'propose' OU 'contre_offre' dès qu'on l'appelle, sans plus de garde
--    que le statut du contrat. sql/36 (tel quel dans le repo) ne reflète
--    donc plus ce qui tourne réellement.
--
--    Comme cette fonction touche paiements/indemnités et que je ne connais
--    pas la raison de cette simplification (intentionnelle ? un correctif
--    d'urgence non reversé dans un fichier numéroté ?), je ne l'ai PAS
--    réécrite ici — ni pour la restaurer à sa forme sql/36, ni pour lui
--    ajouter le nouveau state='trusted'/est_bloque. Un changement de
--    comportement sur un chemin qui touche l'argent n'est pas le genre de
--    chose à corriger en silence pendant une tâche de navigation/relations.
--    Signalé à Robert dans le résumé de cette session — à traiter à part.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 10) ouvrir_fil (messagerie, sql/23) — même corps, blocage étendu à
--     est_bloque() (admin + libre-service, les deux directions) au lieu
--     de est_exclu() seul.
-- ---------------------------------------------------------------------
create or replace function public.ouvrir_fil(p_contrat uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_pharmacie uuid; v_pharmacien uuid; v_fil uuid;
begin
  select k.pharmacie_id,
         coalesce(
           (select c.pharmacien_id from public.candidatures c
             where c.contrat_id = k.id and c.statut = 'acceptee' limit 1),
           case when public.mon_role() = 'pharmacien' then auth.uid() else null end)
    into v_pharmacie, v_pharmacien
    from public.contrats k
   where k.id = p_contrat;

  if v_pharmacie is null or v_pharmacien is null then
    raise exception 'Contrat introuvable ou aucun pharmacien rattaché';
  end if;

  if not (public.est_admin() or auth.uid() in (v_pharmacie, v_pharmacien)) then
    raise exception 'Accès refusé';
  end if;

  if public.est_bloque(v_pharmacien, v_pharmacie) then
    raise exception 'Conversation impossible : cette contrepartie n''est pas accessible.';
  end if;

  select id into v_fil from public.fils
   where pharmacie_id = v_pharmacie and pharmacien_id = v_pharmacien
     and statut = 'ouvert' limit 1;

  if v_fil is null then
    insert into public.fils (pharmacie_id, pharmacien_id, contrat_id)
    values (v_pharmacie, v_pharmacien, p_contrat)
    returning id into v_fil;
  end if;

  return v_fil;
end;
$$;
revoke all on function public.ouvrir_fil(uuid) from public, anon;
grant execute on function public.ouvrir_fil(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Vérification après exécution :
--   select state, count(*) from public.favoris_pharmaciens group by 1;
--     -> tout l'existant doit être 'trusted', aucune ligne perdue.
--   select public.est_bloque('<un uuid pharmacien>', '<un uuid pharmacie>');
--     -> false sur une paire quelconque non bloquée.
--   Ouvrir un contrat existant, poster/candidater normalement : aucune
--   régression (une paire ni exclue ni bloquée passe toujours `true`).
-- ---------------------------------------------------------------------
