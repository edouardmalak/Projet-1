-- =====================================================================
-- C-DIRECT · PHASE 5 · SQL 11 — FILE D'ATTENTE SMS + LOTS (DIGESTS)
-- À exécuter APRÈS 10-admin-factures.sql, dans Supabase → SQL Editor.
--
-- · sms_queue : tampon des SMS destinés aux PHARMACIENS (groupage ~5 min
--   + heures de silence 21:00–07:00). Le Worker (service_role) écrit et
--   vide la file via son Cron Trigger chaque minute.
-- · sms_batch : lot de contrats d'une même pharmacie (3+ dans la
--   fenêtre) — la page /nouveaux/{batch_id} liste le lot.
-- =====================================================================

create table if not exists public.sms_queue (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references public.profiles(id) on delete cascade,
  contrat_id uuid references public.contrats(id) on delete cascade,
  pharmacie_id uuid,
  to_number text not null,
  type text not null default 'contrat_nouveau',
  corps text,
  ville text,
  envoyer_apres timestamptz not null default now(),
  statut text not null default 'attente'
    check (statut in ('attente','envoi','envoye','echec','groupe','annule')),
  batch_id uuid,
  created_at timestamptz default now()
);
create index if not exists idx_sms_queue_flush on public.sms_queue (statut, envoyer_apres);

create table if not exists public.sms_batch (
  id uuid primary key default gen_random_uuid(),
  pharmacie_id uuid,
  contrat_ids uuid[] not null,
  created_at timestamptz default now()
);

-- RLS : le Worker passe par service_role (contourne la RLS) ;
-- côté client, seul l'admin peut regarder la tuyauterie.
alter table public.sms_queue enable row level security;
alter table public.sms_batch enable row level security;

drop policy if exists "sms_queue_admin" on public.sms_queue;
create policy "sms_queue_admin" on public.sms_queue
  for all using (public.est_admin()) with check (public.est_admin());

drop policy if exists "sms_batch_admin" on public.sms_batch;
create policy "sms_batch_admin" on public.sms_batch
  for all using (public.est_admin()) with check (public.est_admin());

-- ---------------------------------------------------------------------
-- RPC · get_batch_contrats — la page /nouveaux/{batch_id} : tous les
-- contrats du lot, avec « correspond » = ce contrat avait passé les
-- filtres POUR LE PHARMACIEN CONNECTÉ (ligne sms_queue à son nom).
-- Accessible à tout utilisateur connecté (le lien circule par SMS).
-- ---------------------------------------------------------------------
create or replace function public.get_batch_contrats(p_batch uuid)
returns table (
  contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, correspond boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Connexion requise'; end if;
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.statut, pe.ville,
           exists (select 1 from public.sms_queue q
                    where q.batch_id = p_batch
                      and q.contrat_id = k.id
                      and q.profile_id = auth.uid())
      from public.sms_batch b
      join public.contrats k on k.id = any(b.contrat_ids)
      join public.profiles pe on pe.id = k.pharmacie_id
     where b.id = p_batch
     order by k.date_contrat, k.numero_reference;
end;
$$;
revoke all on function public.get_batch_contrats(uuid) from public, anon;
grant execute on function public.get_batch_contrats(uuid) to authenticated;
