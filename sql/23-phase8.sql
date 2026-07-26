-- =====================================================================
-- C-DIRECT · SQL 23 — PHASE 8
--   A) Majoration automatique du tarif (contrats non pourvus)
--   B) « Ce que vous devez savoir » (fiche d'accueil de la pharmacie)
--   C) Messagerie : un seul fil ouvert par paire + clôture mutuelle
--
-- À exécuter dans Supabase → SQL Editor, APRÈS 22.
-- Idempotent (create or replace / if not exists / add column if not exists).
-- Défensif : tant que ce fichier n'est pas exécuté, les nouvelles UI
-- s'affichent mais indiquent « Non activé » — rien ne casse.
-- =====================================================================


-- =====================================================================
-- A) MAJORATION AUTOMATIQUE DU TARIF
-- La pharmacie décide : « si personne n'a pris le quart, monte le taux
-- de X $ toutes les N heures, sans jamais dépasser Y $ ».
-- =====================================================================

alter table public.profiles
  add column if not exists bump_actif       boolean not null default false,
  add column if not exists bump_increment   numeric(6,2),          -- $ ajoutés à chaque palier
  add column if not exists bump_intervalle_h int,                  -- toutes les N heures
  add column if not exists bump_max         numeric(6,2);          -- plafond absolu $/h

alter table public.contrats
  add column if not exists tarif_initial    numeric(6,2),          -- taux d'origine (mémoire)
  add column if not exists derniere_hausse  timestamptz,           -- dernier palier appliqué
  add column if not exists nb_hausses       int not null default 0;

-- Garde-fous de cohérence (valeurs absurdes refusées)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_bump_coherent') then
    alter table public.profiles add constraint profiles_bump_coherent check (
      bump_actif = false
      or (bump_increment > 0 and bump_increment <= 50
          and bump_intervalle_h >= 1 and bump_intervalle_h <= 168
          and bump_max > 0 and bump_max <= 500)
    );
  end if;
end $$;

-- ---------------------------------------------------------------------
-- appliquer_hausses_auto — appelée par pg_cron (toutes les heures).
-- Ne touche QUE les contrats encore « ouvert », dont la date n'est pas
-- passée, et dont la pharmacie a activé la majoration.
-- ---------------------------------------------------------------------
create or replace function public.appliquer_hausses_auto()
returns TABLE (contrat_id uuid, numero_reference text, ancien numeric, nouveau numeric)
language plpgsql security definer set search_path = public
as $$
begin
  return query
  with candidats as (
    select k.id,
           k.numero_reference,
           k.tarif_horaire as ancien,
           p.bump_increment,
           p.bump_max,
           least(k.tarif_horaire + p.bump_increment, p.bump_max) as nouveau
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
       and k.date_contrat >= current_date
       and p.bump_actif = true
       and p.bump_increment is not null
       and p.bump_intervalle_h is not null
       and p.bump_max is not null
       and k.tarif_horaire < p.bump_max
       and now() - coalesce(k.derniere_hausse, k.created_at)
           >= make_interval(hours => p.bump_intervalle_h)
  ), maj as (
    update public.contrats k
       set tarif_initial   = coalesce(k.tarif_initial, k.tarif_horaire),
           tarif_horaire   = c.nouveau,
           derniere_hausse = now(),
           nb_hausses      = k.nb_hausses + 1
      from candidats c
     where k.id = c.id
       and c.nouveau > c.ancien
    returning k.id, k.numero_reference, c.ancien, k.tarif_horaire
  )
  select * from maj;
end;
$$;
revoke all on function public.appliquer_hausses_auto() from public, anon;
grant execute on function public.appliquer_hausses_auto() to authenticated;

-- Planification horaire (pg_cron déjà utilisé par SQL 08).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('c-direct-hausses-auto')
      where exists (select 1 from cron.job where jobname = 'c-direct-hausses-auto');
    perform cron.schedule('c-direct-hausses-auto', '7 * * * *',
                          $cron$select public.appliquer_hausses_auto();$cron$);
  end if;
end $$;


-- =====================================================================
-- B) « CE QUE VOUS DEVEZ SAVOIR » — fiche d'accueil de la pharmacie
-- Remplie une fois par la pharmacie ; visible par le pharmacien SEULEMENT
-- une fois le contrat attribué (avant : rien, pour protéger la vie privée).
-- =====================================================================

alter table public.profiles
  add column if not exists info_contact_nom   text,
  add column if not exists info_contact_tel   text,
  add column if not exists info_arrivee       text,   -- où se présenter, code de porte…
  add column if not exists info_stationnement text,
  add column if not exists info_instructions  text,   -- consignes libres
  add column if not exists info_plateaux      jsonb not null default '[]'::jsonb;
  -- info_plateaux : [{"couleur":"Rouge","hex":"#C0392B","sens":"Urgences / à faire en premier"}, …]

-- ---------------------------------------------------------------------
-- get_fiche_accueil — la fiche pour UN contrat donné.
-- Accès : l'admin, la pharmacie propriétaire, ou le pharmacien retenu.
-- ---------------------------------------------------------------------
create or replace function public.get_fiche_accueil(p_contrat uuid)
returns table (
  numero_reference text, date_contrat date,
  heure_debut time, heure_fin time,
  nom_pharmacie text, adresse text, ville text, code_postal text,
  logiciel text, telephone text,
  info_contact_nom text, info_contact_tel text,
  info_arrivee text, info_stationnement text, info_instructions text,
  info_plateaux jsonb,
  notes_acces text, rx_jour_semaine int, rx_jour_weekend int
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (
    select 1
      from public.contrats k
      left join public.candidatures c
             on c.contrat_id = k.id
            and c.statut = 'acceptee'
     where k.id = p_contrat
       and ( public.est_admin()
             or k.pharmacie_id = auth.uid()
             or c.pharmacien_id = auth.uid() )
  ) then
    raise exception 'Accès refusé';
  end if;

  return query
    select k.numero_reference, k.date_contrat, k.heure_debut, k.heure_fin,
           p.nom_pharmacie, p.adresse, p.ville, p.code_postal,
           p.logiciel, p.telephone,
           p.info_contact_nom, p.info_contact_tel,
           p.info_arrivee, p.info_stationnement, p.info_instructions,
           coalesce(p.info_plateaux, '[]'::jsonb),
           p.notes_acces, p.rx_jour_semaine, p.rx_jour_weekend
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.id = p_contrat;
end;
$$;
revoke all on function public.get_fiche_accueil(uuid) from public, anon;
grant execute on function public.get_fiche_accueil(uuid) to authenticated;


-- =====================================================================
-- C) MESSAGERIE — un seul fil ouvert par paire pharmacie↔pharmacien,
-- clôture MUTUELLE (les deux doivent accepter).
-- =====================================================================

create table if not exists public.fils (
  id             uuid primary key default gen_random_uuid(),
  pharmacie_id   uuid not null references public.profiles(id) on delete cascade,
  pharmacien_id  uuid not null references public.profiles(id) on delete cascade,
  contrat_id     uuid references public.contrats(id) on delete set null, -- contrat d'origine
  statut         text not null default 'ouvert' check (statut in ('ouvert','ferme')),
  cloture_pharmacie  boolean not null default false,
  cloture_pharmacien boolean not null default false,
  created_at     timestamptz not null default now(),
  ferme_le       timestamptz
);

-- LA règle : un seul fil OUVERT par paire (l'index partiel l'impose en base).
create unique index if not exists fils_un_seul_ouvert
  on public.fils (pharmacie_id, pharmacien_id)
  where statut = 'ouvert';

create index if not exists fils_pharmacie_idx  on public.fils (pharmacie_id);
create index if not exists fils_pharmacien_idx on public.fils (pharmacien_id);

alter table public.fils enable row level security;

drop policy if exists fils_lecture on public.fils;
create policy fils_lecture on public.fils for select
  using (public.est_admin() or pharmacie_id = auth.uid() or pharmacien_id = auth.uid());

-- Rattacher les messages à un fil (l'ancienne colonne contrat_id reste
-- en place : rien ne casse, la migration ci-dessous remplit fil_id).
alter table public.messages
  add column if not exists fil_id uuid references public.fils(id) on delete cascade;

create index if not exists messages_fil_idx on public.messages (fil_id, created_at);

-- ---------------------------------------------------------------------
-- ouvrir_fil — renvoie le fil ouvert de la paire, ou le crée.
-- Le pharmacien et la pharmacie sont déduits du contrat.
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

  -- blocage (SQL 21) : pas de fil avec une contrepartie exclue
  if public.est_exclu(v_pharmacien, v_pharmacie) then
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
-- demander_cloture — chaque partie pose son drapeau ; quand les DEUX
-- l'ont posé, le fil se ferme. Rappeler la fonction annule sa propre
-- demande (permet de se raviser).
-- Renvoie l'état pour que l'UI affiche le bon message.
-- ---------------------------------------------------------------------
create or replace function public.demander_cloture(p_fil uuid, p_veut boolean default true)
returns table (statut text, cloture_pharmacie boolean, cloture_pharmacien boolean)
language plpgsql security definer set search_path = public
as $$
declare v_ph uuid; v_pn uuid;
begin
  select pharmacie_id, pharmacien_id into v_ph, v_pn
    from public.fils where id = p_fil;
  if v_ph is null then raise exception 'Fil introuvable'; end if;
  if auth.uid() not in (v_ph, v_pn) then raise exception 'Accès refusé'; end if;

  update public.fils f
     set cloture_pharmacie  = case when auth.uid() = v_ph then p_veut else f.cloture_pharmacie  end,
         cloture_pharmacien = case when auth.uid() = v_pn then p_veut else f.cloture_pharmacien end
   where f.id = p_fil;

  update public.fils f
     set statut = 'ferme', ferme_le = now()
   where f.id = p_fil
     and f.cloture_pharmacie and f.cloture_pharmacien
     and f.statut = 'ouvert';

  return query
    select f.statut, f.cloture_pharmacie, f.cloture_pharmacien
      from public.fils f where f.id = p_fil;
end;
$$;
revoke all on function public.demander_cloture(uuid, boolean) from public, anon;
grant execute on function public.demander_cloture(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- mes_fils — la liste pour la page Messages (nom de la contrepartie,
-- dernier message, non-lus, état de clôture).
-- ---------------------------------------------------------------------
create or replace function public.mes_fils()
returns table (
  fil_id uuid, statut text,
  cloture_pharmacie boolean, cloture_pharmacien boolean,
  contrepartie_nom text, contrat_ref text,
  dernier_message text, dernier_le timestamptz, nb_messages bigint
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
           (select count(*) from public.messages m where m.fil_id = f.id)
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

-- ---------------------------------------------------------------------
-- Écriture des messages : interdite si le fil est fermé.
-- ---------------------------------------------------------------------
create or replace function public.bloquer_message_fil_ferme()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.fil_id is not null
     and exists (select 1 from public.fils f where f.id = new.fil_id and f.statut = 'ferme') then
    raise exception 'Cette conversation est fermée.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_bloquer_message_fil_ferme on public.messages;
create trigger trg_bloquer_message_fil_ferme
  before insert on public.messages
  for each row execute function public.bloquer_message_fil_ferme();

-- ---------------------------------------------------------------------
-- Migration douce : créer un fil pour chaque conversation existante et
-- y rattacher les anciens messages (aucune perte d'historique).
-- ---------------------------------------------------------------------
do $$
declare r record; v_fil uuid;
begin
  for r in
    select distinct k.pharmacie_id, c.pharmacien_id, m.contrat_id
      from public.messages m
      join public.contrats k on k.id = m.contrat_id
      join public.candidatures c on c.contrat_id = k.id and c.statut = 'acceptee'
     where m.fil_id is null
  loop
    select id into v_fil from public.fils
     where pharmacie_id = r.pharmacie_id and pharmacien_id = r.pharmacien_id
       and statut = 'ouvert' limit 1;
    if v_fil is null then
      insert into public.fils (pharmacie_id, pharmacien_id, contrat_id)
      values (r.pharmacie_id, r.pharmacien_id, r.contrat_id)
      returning id into v_fil;
    end if;
    update public.messages set fil_id = v_fil
     where contrat_id = r.contrat_id and fil_id is null;
  end loop;
end $$;

-- Lecture/écriture des messages via le fil (en plus des anciennes règles)
drop policy if exists messages_lecture_fil on public.messages;
create policy messages_lecture_fil on public.messages for select
  using (
    fil_id is not null and exists (
      select 1 from public.fils f
       where f.id = messages.fil_id
         and (public.est_admin() or auth.uid() in (f.pharmacie_id, f.pharmacien_id)))
  );

drop policy if exists messages_insert_fil on public.messages;
create policy messages_insert_fil on public.messages for insert
  with check (
    expediteur_id = auth.uid()
    and fil_id is not null and exists (
      select 1 from public.fils f
       where f.id = messages.fil_id
         and f.statut = 'ouvert'
         and auth.uid() in (f.pharmacie_id, f.pharmacien_id))
  );
