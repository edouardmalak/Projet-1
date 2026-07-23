-- =====================================================================
-- C-DIRECT · SQL 19 — Évaluations bidirectionnelles (double aveugle)
-- À exécuter dans Supabase → SQL Editor (idempotent).
--
-- Chaque partie d'un contrat COMPLÉTÉ peut noter l'autre (1 à 5 étoiles),
-- indiquer si elle « retravaillerait / réembaucherait », et laisser un
-- commentaire. Les évaluations restent PRIVÉES jusqu'à ce que les DEUX
-- côtés aient soumis, OU jusqu'à 72 h après la date du contrat — la
-- première de ces deux conditions. Cela évite les notes de représailles.
-- =====================================================================

create table if not exists public.evaluations (
  id uuid primary key default gen_random_uuid(),
  contrat_id uuid not null references public.contrats(id) on delete cascade,
  auteur_id uuid not null references public.profiles(id) on delete cascade,
  auteur_role text not null check (auteur_role in ('pharmacien','pharmacie')),
  cible_id uuid references public.profiles(id) on delete set null,
  note int not null check (note between 1 and 5),
  reviendrait boolean,
  commentaire text check (char_length(commentaire) <= 1000),
  created_at timestamptz not null default now(),
  unique (contrat_id, auteur_id)
);
create index if not exists idx_eval_contrat on public.evaluations(contrat_id);
create index if not exists idx_eval_cible on public.evaluations(cible_id);
create index if not exists idx_eval_auteur on public.evaluations(auteur_id);

-- RLS : un usager ne lit DIRECTEMENT que ses propres évaluations émises.
-- Tout le reste (notes reçues révélées, moyennes) passe par des fonctions
-- SECURITY DEFINER ci-dessous, qui appliquent la règle du double aveugle.
alter table public.evaluations enable row level security;
drop policy if exists "eval_lecture_propre" on public.evaluations;
create policy "eval_lecture_propre" on public.evaluations for select
  using (auteur_id = auth.uid());

-- ---------------------------------------------------------------------
-- Une évaluation d'un contrat est-elle RÉVÉLÉE ?
--   • les deux côtés ont soumis (2 rôles distincts), OU
--   • plus de 72 h depuis la date du contrat.
-- ---------------------------------------------------------------------
create or replace function public.eval_contrat_revele(p_contrat uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select (
    (select count(distinct auteur_role) from public.evaluations where contrat_id = p_contrat) >= 2
  ) or (
    coalesce((select date_contrat from public.contrats where id = p_contrat), current_date)
      + interval '72 hours' < now()
  );
$$;

-- ---------------------------------------------------------------------
-- Soumettre (ou modifier) son évaluation pour un contrat.
-- Vérifie que l'appelant est bien une partie du contrat.
-- ---------------------------------------------------------------------
create or replace function public.soumettre_evaluation(
  p_contrat uuid, p_note int, p_reviendrait boolean, p_commentaire text
) returns void language plpgsql security definer set search_path = public as $$
declare v_role text; v_cible uuid;
begin
  if p_note is null or p_note < 1 or p_note > 5 then
    raise exception 'Note invalide (1 à 5).';
  end if;

  select case when k.pharmacie_id = auth.uid() then 'pharmacie' else 'pharmacien' end
    into v_role
  from public.contrats k
  where k.id = p_contrat
    and (k.pharmacie_id = auth.uid()
         or exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid()
                      and c.statut = 'accepte'));
  if v_role is null then raise exception 'Contrat introuvable ou accès refusé.'; end if;

  if v_role = 'pharmacie' then
    select c.pharmacien_id into v_cible from public.candidatures c
      where c.contrat_id = p_contrat and c.statut = 'accepte' limit 1;
  else
    select k.pharmacie_id into v_cible from public.contrats k where k.id = p_contrat;
  end if;

  insert into public.evaluations
    (contrat_id, auteur_id, auteur_role, cible_id, note, reviendrait, commentaire)
  values
    (p_contrat, auth.uid(), v_role, v_cible, p_note, p_reviendrait, nullif(btrim(p_commentaire),''))
  on conflict (contrat_id, auteur_id) do update
    set note = excluded.note,
        reviendrait = excluded.reviendrait,
        commentaire = excluded.commentaire,
        created_at = now();
end; $$;

-- ---------------------------------------------------------------------
-- Contrats que l'appelant doit encore évaluer (passés, pas encore notés).
-- ---------------------------------------------------------------------
create or replace function public.get_evaluations_a_faire()
returns table (contrat_id uuid, numero_reference text, date_contrat date, autre_nom text, mon_role text)
language sql stable security definer set search_path = public as $$
  select k.id, k.numero_reference, k.date_contrat,
    case when k.pharmacie_id = auth.uid()
      then (select coalesce(nullif(btrim(p.prenom||' '||coalesce(p.nom,'')),''), p.courriel, 'Pharmacien(ne)')
              from public.candidatures c join public.profiles p on p.id = c.pharmacien_id
              where c.contrat_id = k.id and c.statut = 'accepte' limit 1)
      else (select coalesce(p.nom_pharmacie, p.ville, 'Pharmacie')
              from public.profiles p where p.id = k.pharmacie_id)
    end as autre_nom,
    case when k.pharmacie_id = auth.uid() then 'pharmacie' else 'pharmacien' end as mon_role
  from public.contrats k
  where k.statut in ('attribue','complete')
    and k.date_contrat <= current_date
    and (k.pharmacie_id = auth.uid()
         or exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid()
                      and c.statut = 'accepte'))
    and not exists (select 1 from public.evaluations e
                    where e.contrat_id = k.id and e.auteur_id = auth.uid())
  order by k.date_contrat desc;
$$;

-- ---------------------------------------------------------------------
-- Notes REÇUES par l'appelant (uniquement les évaluations révélées).
-- ---------------------------------------------------------------------
create or replace function public.get_evaluations_recues()
returns table (id uuid, note int, reviendrait boolean, commentaire text,
               created_at timestamptz, numero_reference text, date_contrat date)
language sql stable security definer set search_path = public as $$
  select e.id, e.note, e.reviendrait, e.commentaire, e.created_at,
         k.numero_reference, k.date_contrat
  from public.evaluations e
  join public.contrats k on k.id = e.contrat_id
  where e.cible_id = auth.uid()
    and public.eval_contrat_revele(e.contrat_id)
  order by e.created_at desc;
$$;

-- ---------------------------------------------------------------------
-- Moyenne / nombre / taux de « retravaillerait » d'un profil (révélées).
-- ---------------------------------------------------------------------
create or replace function public.get_note_profil(p_profil uuid)
returns table (moyenne numeric, nombre bigint, taux_reviendrait int)
language sql stable security definer set search_path = public as $$
  select round(avg(e.note), 2),
         count(*),
         coalesce(round(100.0 * count(*) filter (where e.reviendrait)
                        / nullif(count(*) filter (where e.reviendrait is not null), 0)), 0)::int
  from public.evaluations e
  where e.cible_id = p_profil
    and public.eval_contrat_revele(e.contrat_id);
$$;

grant execute on function public.soumettre_evaluation(uuid,int,boolean,text) to authenticated;
grant execute on function public.get_evaluations_a_faire() to authenticated;
grant execute on function public.get_evaluations_recues() to authenticated;
grant execute on function public.get_note_profil(uuid) to authenticated;
grant execute on function public.eval_contrat_revele(uuid) to authenticated;
