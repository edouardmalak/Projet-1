-- =====================================================================
-- C-DIRECT · SQL 18 — Messagerie (chat) par contrat
-- À exécuter dans Supabase → SQL Editor (idempotent).
-- Une conversation par contrat, entre la pharmacie propriétaire et le
-- pharmacien dont la candidature est ACCEPTÉE (+ admin). La RLS garantit
-- que seules ces deux parties voient/écrivent les messages.
-- =====================================================================

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  expediteur_id uuid not null references public.profiles(id) on delete cascade,
  corps text not null check (char_length(corps) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists idx_messages_contrat on public.messages(contrat_id, created_at);

-- Suis-je partie de ce contrat ? (pharmacie propriétaire, pharmacien retenu, admin)
create or replace function public.est_partie_contrat(p_contrat uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.contrats k
                  where k.id = p_contrat and (k.pharmacie_id = auth.uid() or public.est_admin()))
      or exists (select 1 from public.candidatures c
                  where c.contrat_id = p_contrat and c.pharmacien_id = auth.uid() and c.statut = 'accepte');
$$;

alter table public.messages enable row level security;

drop policy if exists "messages_lecture" on public.messages;
create policy "messages_lecture" on public.messages for select
  using (public.est_partie_contrat(contrat_id));

drop policy if exists "messages_insert" on public.messages;
create policy "messages_insert" on public.messages for insert
  with check (expediteur_id = auth.uid() and public.est_partie_contrat(contrat_id));
