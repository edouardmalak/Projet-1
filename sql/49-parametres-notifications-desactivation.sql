-- 49 — Paramètres du compte : préférences de notification (push) +
-- désactivation volontaire de compte + table des abonnements Web Push.
--
-- Les colonnes de préférences se mettent à jour par UPDATE direct du
-- client (profiles_update_soi, sql/01, autorise déjà id = auth.uid()) —
-- pas besoin de RPC pour ça. Seule la désactivation a une RPC dédiée,
-- pour nettoyer push_subscriptions dans la même transaction.

alter table public.profiles
  add column if not exists notif_push_actif boolean not null default true,
  add column if not exists notif_seulement_logiciel_connu boolean not null default false,
  add column if not exists notif_distance_max_km integer,
  add column if not exists notif_evaluations boolean not null default true,
  add column if not exists compte_desactive boolean not null default false,
  add column if not exists compte_desactive_le timestamptz;

-- ---------------------------------------------------------------------
-- Abonnements Web Push (un navigateur/appareil = une ligne). L'endpoint
-- + les clés p256dh/auth viennent de PushManager.subscribe() côté client.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  profil_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  unique(profil_id, endpoint)
);
alter table public.push_subscriptions enable row level security;

drop policy if exists "push_subscriptions_select_soi" on public.push_subscriptions;
create policy "push_subscriptions_select_soi" on public.push_subscriptions
  for select using (profil_id = auth.uid());

drop policy if exists "push_subscriptions_insert_soi" on public.push_subscriptions;
create policy "push_subscriptions_insert_soi" on public.push_subscriptions
  for insert with check (profil_id = auth.uid());

drop policy if exists "push_subscriptions_delete_soi" on public.push_subscriptions;
create policy "push_subscriptions_delete_soi" on public.push_subscriptions
  for delete using (profil_id = auth.uid());

-- service_role (Worker, pour l'envoi) contourne RLS nativement —
-- aucune politique additionnelle requise pour la lecture côté Worker.

-- ---------------------------------------------------------------------
-- Désactivation volontaire : réversible seulement par un admin (aucune
-- UI de réactivation pour l'instant — cohérent avec la demande, qui ne
-- mentionne qu'un bouton de désactivation). Nettoie aussi les abonnements
-- push. NE TOUCHE PAS à auth.users, contrairement à supprimer_mon_compte()
-- (sql/01) : ceci est réversible et conserve les données (historique de
-- contrats/factures, obligations fiscales) — les deux fonctions coexistent
-- pour deux usages différents.
create or replace function public.desactiver_mon_compte()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Non connecté'; end if;
  update public.profiles set compte_desactive = true, compte_desactive_le = now() where id = auth.uid();
  delete from public.push_subscriptions where profil_id = auth.uid();
end;
$$;
revoke all on function public.desactiver_mon_compte() from public, anon;
grant execute on function public.desactiver_mon_compte() to authenticated;

-- ---------------------------------------------------------------------
-- compter_compatibles (sql/48) : un pharmacien qui a désactivé son compte
-- ne doit plus compter comme « compatible » pour une pharmacie qui publie
-- un contrat, même si calendrier/tarif seraient autrement compatibles.
create or replace function public.compter_compatibles(p_date date, p_tarif numeric)
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_pe public.profiles; n integer;
begin
  select * into v_pe from public.profiles where id = auth.uid();
  if v_pe.role not in ('pharmacie','admin') then raise exception 'Accès refusé'; end if;

  select count(*) into n from public.profiles pn
   where pn.role = 'pharmacien' and coalesce(pn.approuve,false) = true
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
revoke all on function public.compter_compatibles(date, numeric) from public, anon;
grant execute on function public.compter_compatibles(date, numeric) to authenticated;
