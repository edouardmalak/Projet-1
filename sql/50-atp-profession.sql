-- =====================================================================
-- C-DIRECT · SQL 50 — PROFESSION ATP (pipeline étendu, pas un rôle séparé)
-- À exécuter dans Supabase → SQL Editor, APRÈS 49-parametres-notifications-desactivation.sql.
--
-- Décision (validée par Robert) : les ATP (Assistant(e)s Technique(s) en
-- Pharmacie) utilisent EXACTEMENT le même pipeline candidat que les
-- pharmacien(ne)s — même role='pharmacien' pour tout le contrôle d'accès
-- existant (RLS, cdExigerConnexion(['pharmacien']), calendrier, mandats,
-- messages, paramètres… rien de tout ça ne change). On ajoute juste une
-- sous-dimension `profession` ('pharmacien'|'atp') qui sert UNIQUEMENT à :
--   1) l'appariement contrat ↔ candidat (une pharmacie choisit qui elle
--      cherche ; seuls les comptes de cette profession voient/postulent) ;
--   2) l'étiquette affichée.
-- Tarifs/indemnités (regles_reseau, cdEstimation) restent PARTAGÉS entre
-- les deux professions pour l'instant (décision Robert — à séparer plus
-- tard si des tarifs ATP distincts sont voulus).
-- Idempotent (add column if not exists / create or replace / drop-then-create).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) profiles.profession — pertinent seulement pour role='pharmacien'.
--    Rétro-compatibilité : tous les comptes pharmacien existants sont
--    rétro-étiquetés 'pharmacien' (comportement identique à avant).
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists profession text check (profession in ('pharmacien','atp'));

update public.profiles set profession = 'pharmacien'
 where role = 'pharmacien' and profession is null;

-- Garde-fou anti-escalade (même logique que empecher_changement_role,
-- sql/01) : une fois définie, la profession n'est modifiable que par un
-- admin — empêche un compte de se reclasser après vérification.
create or replace function public.empecher_changement_profession()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.profession is not null and new.profession is distinct from old.profession
     and not public.est_admin() then
    raise exception 'Modification de la profession interdite';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_empecher_changement_profession on public.profiles;
create trigger trg_empecher_changement_profession
  before update on public.profiles
  for each row execute function public.empecher_changement_profession();

-- handle_new_user (sql/01) : reprendre aussi `profession` depuis les
-- métadonnées d'inscription par courriel. Le flux Google (« compléter »,
-- acces.html) écrit directement via update/insert profiles côté client,
-- pas via ce trigger — inchangé ici, corps identique au fichier 01 sauf
-- l'ajout de la colonne profession.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, role, profession, nom, prenom, courriel, telephone, consentement_date)
  values (
    new.id,
    nullif(new.raw_user_meta_data->>'role',''),
    nullif(new.raw_user_meta_data->>'profession',''),
    nullif(new.raw_user_meta_data->>'nom',''),
    nullif(new.raw_user_meta_data->>'prenom',''),
    new.email,
    nullif(new.raw_user_meta_data->>'telephone',''),
    case when (new.raw_user_meta_data->>'consentement') = 'true'
         then coalesce((new.raw_user_meta_data->>'consentement_date')::timestamptz, now())
         else null end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 2) contrats.profession_recherchee — qui la pharmacie cherche pour ce
--    contrat. Défaut 'pharmacien' : tous les contrats existants gardent
--    exactement leur sens actuel sans rien à backfiller (défaut constant
--    Postgres = backfill immédiat, sans réécrire la table).
-- ---------------------------------------------------------------------
alter table public.contrats
  add column if not exists profession_recherchee text
    check (profession_recherchee in ('pharmacien','atp')) not null default 'pharmacien';

-- ---------------------------------------------------------------------
-- 3) Sécurité candidatures — l'insertion se fait par écriture directe du
--    client (contrat.html → sb.from('candidatures').insert(...)), gardée
--    seulement par RLS (pas de RPC intermédiaire). Sans ce garde-fou, un
--    client ATP pourrait techniquement postuler à un contrat cherchant un
--    pharmacien (et vice-versa) en appelant l'API directement.
-- ---------------------------------------------------------------------
create or replace function public.profession_correspond(p_contrat uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select profession from public.profiles where id = auth.uid()),
    'pharmacien'
  ) = (
    select profession_recherchee from public.contrats where id = p_contrat
  );
$$;
revoke all on function public.profession_correspond(uuid) from public, anon;
grant execute on function public.profession_correspond(uuid) to authenticated;

drop policy if exists "candidatures_insert" on public.candidatures;
create policy "candidatures_insert" on public.candidatures for insert with check (
  public.est_admin()
  or (
    pharmacien_id = auth.uid()
    and public.mon_role() = 'pharmacien'
    and public.contrat_est_ouvert(contrat_id)
    and public.profession_correspond(contrat_id)
  )
);

-- ---------------------------------------------------------------------
-- 4) get_contrats_ouverts — un pharmacien ne voit que les contrats qui le
--    cherchent lui (pharmacien), un ATP que ceux qui cherchent un ATP.
--    (reprend sql/21 + filtre profession ; admin continue de tout voir.)
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean,
  profession_recherchee text
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
           k.profession_recherchee
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
       and (
         public.est_admin()
         or (
           not public.est_exclu(auth.uid(), k.pharmacie_id)
           and k.profession_recherchee = coalesce(
             (select profession from public.profiles where id = auth.uid()), 'pharmacien')
         )
       )
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- 5) get_contrat_fiche — même règle pour la fiche : un contrat OUVERT ne
--    s'affiche à un pharmacien/ATP que si sa profession correspond. Une
--    candidature déjà déposée (a_postule) reste consultable quel que soit
--    l'état actuel (la correspondance a déjà été vérifiée à l'insertion).
--    (reprend sql/21 + filtre profession.)
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
  profession_recherchee text
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
           (k.pharmacie_id = auth.uid()),
           k.profession_recherchee
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
                  (select profession from public.profiles where id = auth.uid()), 'pharmacien'))
               or public.a_postule(k.id)
             )
             and not public.est_exclu(auth.uid(), k.pharmacie_id))
       );
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- 6) compter_compatibles — l'indice « N compatibles » du formulaire de
--    publication (espace-pharmacie.html) doit compter la bonne profession.
--    Nouveau paramètre p_profession (défaut 'pharmacien' = comportement
--    identique à avant pour tout appelant qui ne le passe pas encore).
--    (reprend sql/49 + paramètre profession.)
-- ---------------------------------------------------------------------
drop function if exists public.compter_compatibles(date, numeric);
create or replace function public.compter_compatibles(p_date date, p_tarif numeric, p_profession text default 'pharmacien')
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_pe public.profiles; n integer; v_prof text;
begin
  select * into v_pe from public.profiles where id = auth.uid();
  if v_pe.role not in ('pharmacie','admin') then raise exception 'Accès refusé'; end if;
  v_prof := case when p_profession in ('pharmacien','atp') then p_profession else 'pharmacien' end;

  select count(*) into n from public.profiles pn
   where pn.role = 'pharmacien' and coalesce(pn.profession,'pharmacien') = v_prof
     and coalesce(pn.approuve,false) = true
     and coalesce(pn.compte_desactive,false) = false
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
revoke all on function public.compter_compatibles(date, numeric, text) from public, anon;
grant execute on function public.compter_compatibles(date, numeric, text) to authenticated;
