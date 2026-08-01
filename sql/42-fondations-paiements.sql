-- =====================================================================
-- C-DIRECT · PAIEMENTS STRIPE · SQL 42 — FONDATIONS
-- À exécuter dans Supabase → SQL Editor.
--
-- Ce fichier ne fait AUCUN appel Stripe (aucune clé API n'est utilisée
-- ici). Il pose seulement les fondations de données nécessaires avant
-- de construire les routes du Worker "c-direct-payments" :
--   1. photo de profil (écran anti-fraude — identité du pharmacien
--      affichée avant les instructions de paiement)
--   2. courriel Interac vérifié (avec jeton + fenêtre de gel de 72h
--      après tout changement, exigence anti-fraude)
--   3. identifiants Stripe (customer côté pharmacie, compte connecté
--      côté pharmacien)
--
-- Sécurité : les colonnes stripe_* et l'état de vérification Interac ne
-- sont JAMAIS modifiables directement par le client (RLS : select seul).
-- Seules les fonctions SECURITY DEFINER ci-dessous, ou le rôle service
-- (utilisé plus tard par le Worker), peuvent les écrire — même logique
-- que la protection du champ "role" dans sql/01.
-- =====================================================================

-- ---------- 1. PHOTO DE PROFIL (bénin, comme les autres champs profil) ----------
alter table public.profiles
  add column if not exists photo_url text;

-- ---------- 2. VÉRIFICATION DU COURRIEL INTERAC ----------
create table if not exists public.verification_interac (
  profil_id uuid primary key references public.profiles(id) on delete cascade,
  courriel text,
  verifie boolean not null default false,
  token uuid,
  token_expire timestamptz,
  verifie_le timestamptz,
  cooldown_jusqua timestamptz,      -- pendant ce délai (72h après un CHANGEMENT),
                                     -- aucune instruction de paiement Interac n'est
                                     -- émise pour ce profil : tout route vers la carte.
  updated_at timestamptz default now()
);

alter table public.verification_interac enable row level security;

drop policy if exists "verification_interac_select_soi" on public.verification_interac;
create policy "verification_interac_select_soi" on public.verification_interac
  for select using (profil_id = auth.uid() or public.est_admin());
-- Volontairement AUCUNE politique insert/update/delete pour authenticated/anon :
-- toute écriture passe par les fonctions ci-dessous (security definer).

create or replace function public.demander_verification_courriel_interac(p_courriel text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Non connecté';
  end if;
  if p_courriel is null or p_courriel !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Courriel invalide';
  end if;

  insert into public.verification_interac (profil_id, courriel, token, token_expire, verifie)
  values (auth.uid(), trim(p_courriel), gen_random_uuid(), now() + interval '24 hours', false)
  on conflict (profil_id) do update
    set courriel = excluded.courriel,
        token = excluded.token,
        token_expire = excluded.token_expire,
        updated_at = now();
  -- L'envoi du courriel de vérification (via Resend) est branché dans une
  -- passe ultérieure, avec le reste de l'intégration Stripe/écrans.
end;
$$;
revoke all on function public.demander_verification_courriel_interac(text) from public, anon;
grant execute on function public.demander_verification_courriel_interac(text) to authenticated;

create or replace function public.confirmer_verification_courriel_interac(p_token uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.verification_interac%rowtype;
  v_etait_deja_verifie boolean;
begin
  if auth.uid() is null then
    raise exception 'Non connecté';
  end if;

  select * into v_row from public.verification_interac
   where profil_id = auth.uid() and token = p_token;
  if not found then
    raise exception 'Jeton invalide';
  end if;
  if v_row.token_expire < now() then
    raise exception 'Jeton expiré — redemandez un courriel de vérification';
  end if;

  v_etait_deja_verifie := v_row.verifie;

  update public.verification_interac
     set verifie = true,
         verifie_le = now(),
         token = null,
         token_expire = null,
         -- fenêtre de gel de 72h UNIQUEMENT si un courriel déjà vérifié change
         -- (première vérification = aucun gel, rien à protéger encore)
         cooldown_jusqua = case when v_etait_deja_verifie then now() + interval '72 hours' else null end,
         updated_at = now()
   where profil_id = auth.uid();

  return jsonb_build_object(
    'verifie', true,
    'cooldown_jusqua', case when v_etait_deja_verifie then now() + interval '72 hours' else null end
  );
end;
$$;
revoke all on function public.confirmer_verification_courriel_interac(uuid) from public, anon;
grant execute on function public.confirmer_verification_courriel_interac(uuid) to authenticated;

-- ---------- 3. IDENTIFIANTS STRIPE ----------
create table if not exists public.stripe_comptes (
  profil_id uuid primary key references public.profiles(id) on delete cascade,
  stripe_customer_id text,          -- pharmacie : customer PLATEFORME (carte "garantie de paiement")
  stripe_account_id text,           -- pharmacien : compte CONNECTÉ Express (reçoit les charges directes)
  stripe_account_statut jsonb,      -- cache de account.updated (charges_enabled, payouts_enabled, requirements) — rempli plus tard
  updated_at timestamptz default now()
);

alter table public.stripe_comptes enable row level security;

drop policy if exists "stripe_comptes_select_soi" on public.stripe_comptes;
create policy "stripe_comptes_select_soi" on public.stripe_comptes
  for select using (profil_id = auth.uid() or public.est_admin());
-- Volontairement AUCUNE politique insert/update/delete pour authenticated/anon :
-- ces identifiants ne sont écrits que par le rôle service (le Worker
-- c-direct-payments, avec SUPABASE_SERVICE_ROLE_KEY, qui contourne RLS),
-- jamais par le client. Un utilisateur ne peut donc jamais s'attribuer
-- ou falsifier un identifiant Stripe.
