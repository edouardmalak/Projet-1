-- =====================================================================
-- C-DIRECT · PHASE 1 · SQL 01 — AUTH + PROFILES + CONSENTEMENT
-- À exécuter dans Supabase → SQL Editor (en premier).
-- =====================================================================

-- ---------- TABLE PROFILES ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text check (role in ('pharmacien','pharmacie','admin')),
  nom text,
  prenom text,
  courriel text,
  telephone text,                                   -- E.164 : +1XXXXXXXXXX
  consentement_date timestamptz,                    -- consentement politique de confidentialité
  sms_optin boolean default false,
  sms_optin_date timestamptz,
  telephone_verifie boolean default false,          -- (phase future)

  -- Pharmacien
  numero_opq text,
  ville_base text,
  code_postal text,
  rayon_deplacement_km int,
  tarif_horaire_min numeric,
  logiciels text[],
  competences text[],                               -- (phase future)

  -- Pharmacie
  nom_pharmacie text,
  banniere text,
  adresse text,
  ville text,
  neq text,
  contact_proprietaire text,
  cell_proprietaire text,
  logiciel text,
  notes_acces text,
  rx_jour_semaine int,
  rx_jour_weekend int,

  created_at timestamptz default now()
);
-- NOTE : role est nullable volontairement — un compte créé via Google OAuth
-- n'a pas encore de rôle ; l'interface force l'étape « compléter le profil ».

-- ---------- TRIGGER : créer le profil à l'inscription ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, role, nom, prenom, courriel, telephone, consentement_date)
  values (
    new.id,
    nullif(new.raw_user_meta_data->>'role',''),
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

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- HELPERS SÉCURITÉ (security definer : jamais confiance au client) ----------
create or replace function public.est_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function public.mon_role()
returns text
language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ---------- ANTI-ESCALADE : seul un admin peut changer un rôle déjà défini ----------
create or replace function public.empecher_changement_role()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.role is not null and new.role is distinct from old.role and not public.est_admin() then
    raise exception 'Modification du rôle interdite';
  end if;
  -- le premier choix de rôle (compte Google) est limité aux rôles publics
  if old.role is null and new.role = 'admin' and not public.est_admin() then
    raise exception 'Modification du rôle interdite';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_empecher_changement_role on public.profiles;
create trigger trg_empecher_changement_role
  before update on public.profiles
  for each row execute function public.empecher_changement_role();

-- ---------- RLS PROFILES (politiques propres au compte ; le reste au fichier 03) ----------
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_soi" on public.profiles;
create policy "profiles_select_soi" on public.profiles
  for select using (id = auth.uid() or public.est_admin());

drop policy if exists "profiles_update_soi" on public.profiles;
create policy "profiles_update_soi" on public.profiles
  for update using (id = auth.uid() or public.est_admin());

drop policy if exists "profiles_insert_soi" on public.profiles;
create policy "profiles_insert_soi" on public.profiles
  for insert with check (id = auth.uid());

-- ---------- SUPPRESSION DE COMPTE (cascade via FK) ----------
create or replace function public.supprimer_mon_compte()
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Non connecté';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;
revoke all on function public.supprimer_mon_compte() from public, anon;
grant execute on function public.supprimer_mon_compte() to authenticated;

-- ---------- PROMOTION ADMIN ----------
-- À exécuter APRÈS avoir créé le compte edouardmalak@gmail.com via la page d'accès.
-- IMPORTANT : les triggers anti-escalade (trg_empecher_changement_role et
-- trg_empecher_approbation, ce dernier défini au fichier 12) BLOQUENT tout
-- passage à « admin » tant qu'aucun admin n'existe (poule-et-œuf). Il faut
-- donc les désactiver le temps de promouvoir le PREMIER admin, puis les
-- réactiver. On approuve aussi le compte d'office.
begin;
alter table public.profiles disable trigger trg_empecher_changement_role;
-- trg_empecher_approbation n'existe qu'après l'exécution du fichier 12 :
do $$ begin
  if exists (select 1 from pg_trigger where tgname = 'trg_empecher_approbation') then
    execute 'alter table public.profiles disable trigger trg_empecher_approbation';
  end if;
end $$;
update public.profiles p
   set role = 'admin'
  from auth.users u
 where u.id = p.id and u.email = 'edouardmalak@gmail.com';
-- approuve / approuve_date n'existent qu'après le fichier 12 :
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='profiles' and column_name='approuve') then
    execute $q$update public.profiles p
                  set approuve = true, approuve_date = coalesce(approuve_date, now())
                 from auth.users u
                where u.id = p.id and u.email = 'edouardmalak@gmail.com'$q$;
  end if;
end $$;
alter table public.profiles enable trigger trg_empecher_changement_role;
do $$ begin
  if exists (select 1 from pg_trigger where tgname = 'trg_empecher_approbation') then
    execute 'alter table public.profiles enable trigger trg_empecher_approbation';
  end if;
end $$;
commit;
