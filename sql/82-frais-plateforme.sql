-- =====================================================================
-- 82 — FRAIS DE PLATEFORME RÉGLABLES PAR L'ADMIN
-- =====================================================================
-- Contexte (2026-08-18) : les 39 $ de frais C-Direct par quart étaient
-- écrits en dur à DEUX endroits (workers/c-direct-payments/src/index.js
-- et fsa-qc.js). Impossible de les changer sans redéployer, donc
-- impossible de tester le rail de paiement à 0 $ de frais.
--
-- Ce script crée un réglage unique en base, modifiable depuis
-- Administration → « Frais de plateforme », avec historique de qui a
-- changé quoi et quand — même patron que auto_accept_admin_settings
-- (sql/68) et regles_reseau (sql/02).
--
-- VALEUR POSÉE ICI : 0 $ — on est en phase de test, on ne veut pas de
-- frais C-Direct sur les quarts d'essai. Le DÉFAUT de la colonne reste
-- 39 $ : c'est le vrai prix du produit, à remettre avant le lancement.
--
-- IDEMPOTENT : peut être relancé sans risque (ne réécrase pas la valeur
-- déjà en place).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) LE RÉGLAGE (ligne unique id=1)
-- ---------------------------------------------------------------------
create table if not exists public.parametres_plateforme (
  id int primary key default 1 check (id = 1),
  frais_cdirect_dollars numeric not null default 39
    check (frais_cdirect_dollars >= 0 and frais_cdirect_dollars <= 1000),
  updated_at timestamptz not null default now()
);

-- 0 $ pour la phase de test. Le `on conflict do nothing` garantit qu'un
-- second passage du script ne remet PAS la valeur à 0 si l'admin l'a
-- entre-temps remontée à 39.
insert into public.parametres_plateforme (id, frais_cdirect_dollars)
values (1, 0)
on conflict (id) do nothing;

drop trigger if exists trg_param_plateforme_updated on public.parametres_plateforme;
create trigger trg_param_plateforme_updated
  before update on public.parametres_plateforme
  for each row execute function public.toucher_updated_at();

-- ---------------------------------------------------------------------
-- 2) HISTORIQUE — une ligne par changement : qui, quand, ancien → nouveau
-- ---------------------------------------------------------------------
create table if not exists public.parametres_plateforme_history (
  id uuid primary key default gen_random_uuid(),
  modifie_par uuid references public.profiles(id) on delete set null,
  modifie_le timestamptz not null default now(),
  champ text not null,
  ancienne_valeur text,
  nouvelle_valeur text
);

create or replace function public.journaliser_parametres_plateforme()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.frais_cdirect_dollars is distinct from old.frais_cdirect_dollars then
    insert into public.parametres_plateforme_history
      (modifie_par, champ, ancienne_valeur, nouvelle_valeur)
    values (auth.uid(), 'frais_cdirect_dollars',
            old.frais_cdirect_dollars::text, new.frais_cdirect_dollars::text);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_param_plateforme_historique on public.parametres_plateforme;
create trigger trg_param_plateforme_historique
  after update on public.parametres_plateforme
  for each row execute function public.journaliser_parametres_plateforme();

-- ---------------------------------------------------------------------
-- 3) ÉCRITURE — admin seulement, et jamais en direct sur la table.
--    Garde-fou : au-dessus de 100 $ par quart, il faut confirmer
--    explicitement (même logique que la prime > 15 $/h de sql/68) —
--    un zéro de trop sur ce champ facture 390 $ à chaque pharmacie.
-- ---------------------------------------------------------------------
create or replace function public.modifier_frais_plateforme(
  p_frais numeric,
  p_confirmer_frais_eleve boolean default false
)
returns numeric
language plpgsql security definer set search_path = public
as $$
declare
  v_nouveau numeric;
begin
  if not public.est_admin() then
    raise exception 'Accès refusé';
  end if;
  if p_frais is null or p_frais < 0 then
    raise exception 'Frais invalides : la valeur doit être 0 ou plus.';
  end if;
  if p_frais > 100 and not coalesce(p_confirmer_frais_eleve, false) then
    raise exception 'Frais > 100 $ par quart : confirmation explicite requise (p_confirmer_frais_eleve = true)';
  end if;

  update public.parametres_plateforme
     set frais_cdirect_dollars = p_frais
   where id = 1
  returning frais_cdirect_dollars into v_nouveau;

  return v_nouveau;
end;
$$;
revoke all on function public.modifier_frais_plateforme(numeric, boolean) from public, anon;
grant execute on function public.modifier_frais_plateforme(numeric, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 4) LECTURE — le montant des frais n'est pas un secret : il est affiché
--    sur la page de réservation (double tarification). Cette fonction le
--    rend lisible par tous SANS ouvrir la table elle-même.
-- ---------------------------------------------------------------------
create or replace function public.frais_plateforme()
returns numeric
language sql stable security definer set search_path = public
as $$
  select frais_cdirect_dollars from public.parametres_plateforme where id = 1;
$$;
revoke all on function public.frais_plateforme() from public;
grant execute on function public.frais_plateforme() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 5) VERROUS — la table est lisible par l'admin seulement ; aucune
--    politique d'écriture n'existe, tout passe par la RPC ci-dessus.
--    Le Worker de paiement lit avec la clé service_role, qui contourne
--    RLS : il n'est pas concerné par ces politiques.
-- ---------------------------------------------------------------------
alter table public.parametres_plateforme enable row level security;
drop policy if exists param_plateforme_select on public.parametres_plateforme;
create policy param_plateforme_select on public.parametres_plateforme
  for select using (public.est_admin());

alter table public.parametres_plateforme_history enable row level security;
drop policy if exists param_plateforme_hist_select on public.parametres_plateforme_history;
create policy param_plateforme_hist_select on public.parametres_plateforme_history
  for select using (public.est_admin());

-- ---------------------------------------------------------------------
-- VÉRIFICATION
-- ---------------------------------------------------------------------
select 'frais en vigueur' as etape,
       public.frais_plateforme() as frais_cdirect_dollars;
