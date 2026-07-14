-- =====================================================================
-- C-DIRECT · PHASE 1 · SQL 02 — SCHÉMA COMPLET
-- À exécuter APRÈS 01-auth-profiles.sql.
-- Les colonnes « (phases futures) » sont créées maintenant pour ne
-- jamais avoir à migrer des tables en production.
-- =====================================================================

-- ---------- CONTRATS ----------
create table if not exists public.contrats (
  id uuid primary key default gen_random_uuid(),
  numero_reference text unique,                    -- CD-100001, CD-100002, …
  pharmacie_id uuid not null references public.profiles(id) on delete cascade,
  date_contrat date not null,
  heure_debut time not null,
  heure_fin time not null,
  tarif_horaire numeric not null,
  rx_jour_semaine int,
  rx_jour_weekend int,
  seul_pharmacien boolean default true,
  atp_presente boolean default true,
  services text[],
  per_diem boolean default false,                  -- (phase future : auto selon distance)
  hebergement boolean default false,               -- (phase future : auto selon distance)
  notes text,
  statut text not null check (statut in ('ouvert','attribue','complete','annule')) default 'ouvert',
  created_at timestamptz default now()
);

-- Numéro de référence séquentiel CD-100001…
create sequence if not exists public.contrats_ref_seq start with 100001;

create or replace function public.attribuer_numero_reference()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.numero_reference is null then
    new.numero_reference := 'CD-' || nextval('public.contrats_ref_seq')::text;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_numero_reference on public.contrats;
create trigger trg_numero_reference
  before insert on public.contrats
  for each row execute function public.attribuer_numero_reference();

-- Plancher tarifaire du réseau appliqué aussi côté base (défense en profondeur)
create or replace function public.verifier_tarif_plancher()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare plancher numeric;
begin
  select tarif_horaire_minimum into plancher from public.regles_reseau where id = 1;
  if plancher is not null and new.tarif_horaire < plancher and not public.est_admin() then
    raise exception 'Tarif horaire sous le plancher du réseau (% $/h)', plancher;
  end if;
  return new;
end;
$$;

-- ---------- CANDIDATURES ----------
create table if not exists public.candidatures (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  statut text not null check (statut in ('propose','contre_offre','accepte','refuse')) default 'propose',
  tarif_propose numeric,
  heure_debut_proposee time,                       -- (phase future)
  heure_fin_proposee time,                         -- (phase future)
  distance_km numeric,                             -- (phase future)
  type_candidature text check (type_candidature in ('instantanee','negociee')) default 'negociee',
  message text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (contrat_id, pharmacien_id)
);

create or replace function public.toucher_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end;
$$;
drop trigger if exists trg_candidatures_updated on public.candidatures;
create trigger trg_candidatures_updated
  before update on public.candidatures
  for each row execute function public.toucher_updated_at();

-- ---------- FACTURES (phases futures — créée maintenant) ----------
create table if not exists public.factures (
  id uuid primary key default gen_random_uuid(),
  candidature_id uuid not null references public.candidatures(id) on delete cascade,
  numero_facture serial,
  heures numeric,
  tarif_horaire numeric,
  km numeric,
  taux_km numeric default 0.70,
  per_diem_montant numeric default 0,
  hebergement_montant numeric default 0,
  total numeric generated always as (
    coalesce(heures,0)*coalesce(tarif_horaire,0)
    + coalesce(km,0)*coalesce(taux_km,0.70)
    + coalesce(per_diem_montant,0)
    + coalesce(hebergement_montant,0)
  ) stored,
  type_facture text check (type_facture in ('contrat','penalite_annulation')) default 'contrat',
  statut text check (statut in ('brouillon','envoyee','payee','en_retard')) default 'brouillon',
  date_envoi timestamptz,
  date_paiement timestamptz,
  date_echeance date,
  created_at timestamptz default now()
);

-- ---------- DISPONIBILITÉS (phases futures) ----------
create table if not exists public.disponibilites (
  id uuid primary key default gen_random_uuid(),
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  date_dispo date not null,
  unique (pharmacien_id, date_dispo)
);

-- ---------- FAVORIS (phases futures) ----------
create table if not exists public.favoris (
  pharmacien_id uuid references public.profiles(id) on delete cascade,
  contrat_id uuid references public.contrats(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (pharmacien_id, contrat_id)
);

-- ---------- RÈGLES DU RÉSEAU (ligne unique id=1) ----------
create table if not exists public.regles_reseau (
  id int primary key default 1 check (id = 1),
  tarif_horaire_minimum numeric not null default 120,
  taux_km numeric not null default 0.70,
  per_diem_jour numeric not null default 50,
  hebergement_jour numeric not null default 250,
  seuil_per_diem_km int not null default 100,      -- aller simple
  seuil_hebergement_km int not null default 100,   -- aller simple
  penalite_annulation_7j_pct int not null default 50,
  penalite_annulation_48h_pct int not null default 100,
  delai_paiement_jours int not null default 30,
  updated_at timestamptz default now()
);
insert into public.regles_reseau (id) values (1) on conflict (id) do nothing;

drop trigger if exists trg_regles_updated on public.regles_reseau;
create trigger trg_regles_updated
  before update on public.regles_reseau
  for each row execute function public.toucher_updated_at();

-- Le trigger du plancher tarifaire dépend de regles_reseau : on l'attache ici.
drop trigger if exists trg_tarif_plancher on public.contrats;
create trigger trg_tarif_plancher
  before insert or update of tarif_horaire on public.contrats
  for each row execute function public.verifier_tarif_plancher();

-- ---------- SMS_LOG (phases futures) ----------
create table if not exists public.sms_log (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete set null,
  contrat_id uuid references public.contrats(id) on delete set null,
  type text,
  to_number text,
  body text,
  twilio_sid text,
  statut text,
  erreur text,
  created_at timestamptz default now()
);

-- ---------- INDEX UTILES ----------
create index if not exists idx_contrats_statut on public.contrats (statut, created_at desc);
create index if not exists idx_contrats_pharmacie on public.contrats (pharmacie_id);
create index if not exists idx_candidatures_contrat on public.candidatures (contrat_id);
create index if not exists idx_candidatures_pharmacien on public.candidatures (pharmacien_id);
