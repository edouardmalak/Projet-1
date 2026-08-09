-- =====================================================================
-- C-DIRECT · SQL 67 — ENTREVUES / RENDEZ-VOUS + EXPÉRIENCE ATP
-- À exécuter dans Supabase → SQL Editor, APRÈS 66-fix-ouvrir-fil-accepte.sql.
--
-- Décisions (validées par Robert) :
--  1) À l'inscription, un(e) pharmacien(ne) OU un(e) ATP doit passer une
--     entrevue d'intégration AVANT l'activation de son compte. Le compte
--     reste « en attente » (attente.html) jusqu'à ce que l'admin approuve
--     après l'entrevue — la logique d'activation (profiles.approuve) ne
--     change pas ; on ajoute seulement le rendez-vous et sa gestion.
--  2) Pour s'inscrire comme ATP : minimum 1 an d'expérience. Champ
--     obligatoire à l'inscription (bloqué sous 1 an côté client, acces.html)
--     + stocké ici (profiles.annees_experience).
--  3) La prise de rendez-vous est « en interne » : l'usager propose une
--     date/heure, l'admin confirme ou propose une autre plage. Aucun outil
--     externe (Calendly, etc.).
--
-- Idempotent (create table if not exists / create or replace / drop-then-create).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) profiles.annees_experience — années d'expérience déclarées.
--    Pertinent surtout pour les ATP (min. 1 an), facultatif ailleurs.
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists annees_experience integer
    check (annees_experience is null or annees_experience >= 0);

-- handle_new_user (sql/01 + sql/50) : reprendre aussi annees_experience
-- depuis les métadonnées d'inscription par courriel. Corps identique à
-- sql/50 + l'ajout de la colonne annees_experience.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, role, profession, nom, prenom, courriel, telephone, consentement_date, annees_experience)
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
         else null end,
    nullif(new.raw_user_meta_data->>'annees_experience','')::integer
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 2) Table rendez_vous — entrevue d'intégration OU demande de soutien.
--    Un usager peut en avoir plusieurs (ex. entrevue + soutien plus tard) ;
--    on gère la « courante » côté client (la plus récente non annulée).
-- ---------------------------------------------------------------------
create table if not exists public.rendez_vous (
  id              uuid primary key default gen_random_uuid(),
  profil_id       uuid not null references public.profiles(id) on delete cascade,
  type            text not null default 'entrevue' check (type in ('entrevue','soutien')),
  statut          text not null default 'demande'
                    check (statut in ('demande','confirme','propose','complete','annule')),
  date_souhaitee  timestamptz,            -- proposée par l'usager
  date_confirmee  timestamptz,            -- fixée/proposée par l'admin
  message         text,                   -- note facultative de l'usager
  note_admin      text,                   -- note interne de l'admin
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists idx_rendez_vous_profil on public.rendez_vous(profil_id);
create index if not exists idx_rendez_vous_statut on public.rendez_vous(statut);

-- maj automatique de updated_at
create or replace function public.rv_touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists trg_rv_touch on public.rendez_vous;
create trigger trg_rv_touch before update on public.rendez_vous
  for each row execute function public.rv_touch_updated_at();

-- ---------------------------------------------------------------------
-- 3) RLS — l'usager voit/insère SES rendez-vous ; l'admin voit tout.
--    Les mises à jour (confirmer/proposer/compléter) passent par des RPC
--    admin (security definer), donc pas de policy update pour l'usager.
-- ---------------------------------------------------------------------
alter table public.rendez_vous enable row level security;

drop policy if exists "rv_select_soi_ou_admin" on public.rendez_vous;
create policy "rv_select_soi_ou_admin" on public.rendez_vous for select using (
  profil_id = auth.uid() or public.est_admin()
);

drop policy if exists "rv_insert_soi" on public.rendez_vous;
create policy "rv_insert_soi" on public.rendez_vous for insert with check (
  profil_id = auth.uid()
);

-- ---------------------------------------------------------------------
-- 4) RPC usager — demander un rendez-vous + lister les siens.
-- ---------------------------------------------------------------------
create or replace function public.demander_rendez_vous(
  p_date_souhaitee timestamptz,
  p_type text default 'entrevue',
  p_message text default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_type text;
begin
  if auth.uid() is null then raise exception 'Non authentifié'; end if;
  v_type := case when p_type in ('entrevue','soutien') then p_type else 'entrevue' end;
  insert into public.rendez_vous (profil_id, type, date_souhaitee, message, statut)
  values (auth.uid(), v_type, p_date_souhaitee, nullif(trim(coalesce(p_message,'')),''), 'demande')
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.demander_rendez_vous(timestamptz, text, text) from public, anon;
grant execute on function public.demander_rendez_vous(timestamptz, text, text) to authenticated;

create or replace function public.mes_rendez_vous()
returns table (
  id uuid, type text, statut text,
  date_souhaitee timestamptz, date_confirmee timestamptz,
  message text, note_admin text, created_at timestamptz
)
language sql stable security definer set search_path = public
as $$
  select id, type, statut, date_souhaitee, date_confirmee, message, note_admin, created_at
    from public.rendez_vous
   where profil_id = auth.uid()
   order by created_at desc;
$$;
revoke all on function public.mes_rendez_vous() from public, anon;
grant execute on function public.mes_rendez_vous() to authenticated;

-- ---------------------------------------------------------------------
-- 5) RPC admin — lister + confirmer / proposer une autre plage / compléter
--    / annuler. Toutes gardées par est_admin().
-- ---------------------------------------------------------------------
create or replace function public.admin_lister_rendez_vous()
returns table (
  id uuid, profil_id uuid, type text, statut text,
  date_souhaitee timestamptz, date_confirmee timestamptz,
  message text, note_admin text, created_at timestamptz,
  prenom text, nom text, courriel text, telephone text,
  role text, profession text, annees_experience integer, approuve boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select r.id, r.profil_id, r.type, r.statut,
           r.date_souhaitee, r.date_confirmee,
           r.message, r.note_admin, r.created_at,
           p.prenom, p.nom, p.courriel, p.telephone,
           p.role, p.profession, p.annees_experience, coalesce(p.approuve,false)
      from public.rendez_vous r
      join public.profiles p on p.id = r.profil_id
     order by
       case r.statut when 'demande' then 0 when 'propose' then 1 when 'confirme' then 2
                     when 'complete' then 3 else 4 end,
       coalesce(r.date_confirmee, r.date_souhaitee, r.created_at) asc;
end;
$$;
revoke all on function public.admin_lister_rendez_vous() from public, anon;
grant execute on function public.admin_lister_rendez_vous() to authenticated;

create or replace function public.admin_maj_rendez_vous(
  p_id uuid,
  p_statut text,
  p_date_confirmee timestamptz default null,
  p_note_admin text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_statut not in ('demande','confirme','propose','complete','annule') then
    raise exception 'Statut invalide';
  end if;
  update public.rendez_vous
     set statut = p_statut,
         date_confirmee = coalesce(p_date_confirmee, date_confirmee),
         note_admin = coalesce(nullif(trim(coalesce(p_note_admin,'')),''), note_admin)
   where id = p_id;
end;
$$;
revoke all on function public.admin_maj_rendez_vous(uuid, text, timestamptz, text) from public, anon;
grant execute on function public.admin_maj_rendez_vous(uuid, text, timestamptz, text) to authenticated;
