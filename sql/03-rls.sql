-- =====================================================================
-- C-DIRECT · PHASE 1 · SQL 03 — ROW LEVEL SECURITY + RPC
-- À exécuter APRÈS 02-schema-complet.sql.
-- Principe : le rôle admin est vérifié via public.est_admin()
-- (security definer) — jamais via une valeur envoyée par le client.
-- =====================================================================

alter table public.contrats       enable row level security;
alter table public.candidatures   enable row level security;
alter table public.factures       enable row level security;
alter table public.disponibilites enable row level security;
alter table public.favoris        enable row level security;
alter table public.regles_reseau  enable row level security;
alter table public.sms_log        enable row level security;

-- =====================================================================
-- HELPERS security definer (évitent la récursion RLS entre tables)
-- =====================================================================
create or replace function public.a_postule(p_contrat uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.candidatures
                  where contrat_id = p_contrat and pharmacien_id = auth.uid());
$$;

create or replace function public.contrat_de_ma_pharmacie(p_contrat uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.contrats
                  where id = p_contrat and pharmacie_id = auth.uid());
$$;

create or replace function public.contrat_est_ouvert(p_contrat uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.contrats
                  where id = p_contrat and statut = 'ouvert');
$$;

create or replace function public.partie_de_la_facture(p_candidature uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
    where c.id = p_candidature
      and (c.pharmacien_id = auth.uid() or k.pharmacie_id = auth.uid())
  );
$$;

-- =====================================================================
-- CONTRATS
-- =====================================================================
-- Lecture : pharmacie propriétaire · admin · pharmacien connecté
-- (contrats ouverts + ceux où il a postulé)
drop policy if exists "contrats_select" on public.contrats;
create policy "contrats_select" on public.contrats for select using (
  public.est_admin()
  or pharmacie_id = auth.uid()
  or (
    public.mon_role() = 'pharmacien'
    and (statut = 'ouvert' or public.a_postule(id))
  )
);

drop policy if exists "contrats_insert" on public.contrats;
create policy "contrats_insert" on public.contrats for insert with check (
  public.est_admin()
  or (pharmacie_id = auth.uid() and public.mon_role() = 'pharmacie')
);

drop policy if exists "contrats_update" on public.contrats;
create policy "contrats_update" on public.contrats for update using (
  public.est_admin() or pharmacie_id = auth.uid()
);

drop policy if exists "contrats_delete" on public.contrats;
create policy "contrats_delete" on public.contrats for delete using (
  public.est_admin() or pharmacie_id = auth.uid()
);

-- =====================================================================
-- CANDIDATURES
-- =====================================================================
-- Lecture : le pharmacien concerné · la pharmacie du contrat · admin
drop policy if exists "candidatures_select" on public.candidatures;
create policy "candidatures_select" on public.candidatures for select using (
  public.est_admin()
  or pharmacien_id = auth.uid()
  or public.contrat_de_ma_pharmacie(contrat_id)
);

-- Création : un pharmacien, pour lui-même, sur un contrat ouvert
drop policy if exists "candidatures_insert" on public.candidatures;
create policy "candidatures_insert" on public.candidatures for insert with check (
  public.est_admin()
  or (
    pharmacien_id = auth.uid()
    and public.mon_role() = 'pharmacien'
    and public.contrat_est_ouvert(contrat_id)
  )
);

drop policy if exists "candidatures_update" on public.candidatures;
create policy "candidatures_update" on public.candidatures for update using (
  public.est_admin()
  or pharmacien_id = auth.uid()
  or public.contrat_de_ma_pharmacie(contrat_id)
);

drop policy if exists "candidatures_delete" on public.candidatures;
create policy "candidatures_delete" on public.candidatures for delete using (
  public.est_admin() or pharmacien_id = auth.uid()
);

-- =====================================================================
-- FACTURES — visibles par les deux parties ; écriture admin (phase future)
-- =====================================================================
drop policy if exists "factures_select" on public.factures;
create policy "factures_select" on public.factures for select using (
  public.est_admin() or public.partie_de_la_facture(candidature_id)
);
drop policy if exists "factures_admin_ecriture" on public.factures;
create policy "factures_admin_ecriture" on public.factures
  for all using (public.est_admin()) with check (public.est_admin());

-- =====================================================================
-- DISPONIBILITÉS + FAVORIS — propriétaire seulement ; admin en lecture
-- =====================================================================
drop policy if exists "dispo_proprio" on public.disponibilites;
create policy "dispo_proprio" on public.disponibilites
  for all using (pharmacien_id = auth.uid()) with check (pharmacien_id = auth.uid());
drop policy if exists "dispo_admin_lecture" on public.disponibilites;
create policy "dispo_admin_lecture" on public.disponibilites
  for select using (public.est_admin());

drop policy if exists "favoris_proprio" on public.favoris;
create policy "favoris_proprio" on public.favoris
  for all using (pharmacien_id = auth.uid()) with check (pharmacien_id = auth.uid());
drop policy if exists "favoris_admin_lecture" on public.favoris;
create policy "favoris_admin_lecture" on public.favoris
  for select using (public.est_admin());

-- =====================================================================
-- RÈGLES RÉSEAU — lecture connectée ; modification admin
-- =====================================================================
drop policy if exists "regles_lecture" on public.regles_reseau;
create policy "regles_lecture" on public.regles_reseau
  for select using (auth.uid() is not null);
drop policy if exists "regles_admin_maj" on public.regles_reseau;
create policy "regles_admin_maj" on public.regles_reseau
  for update using (public.est_admin()) with check (public.est_admin());

-- =====================================================================
-- SMS_LOG — admin seulement
-- =====================================================================
drop policy if exists "sms_admin" on public.sms_log;
create policy "sms_admin" on public.sms_log
  for all using (public.est_admin()) with check (public.est_admin());

-- =====================================================================
-- RPC · get_candidats — la pharmacie voit UNIQUEMENT nom / prénom /
-- ville_base des pharmaciens ayant postulé à SES contrats.
-- =====================================================================
create or replace function public.get_candidats(p_contrat uuid)
returns table (
  candidature_id uuid, statut text, tarif_propose numeric, message text,
  cree_le timestamptz, pharmacien_id uuid, nom text, prenom text, ville_base text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (
    public.est_admin()
    or exists (select 1 from public.contrats k
                where k.id = p_contrat and k.pharmacie_id = auth.uid())
  ) then
    raise exception 'Accès refusé';
  end if;
  return query
    select c.id, c.statut, c.tarif_propose, c.message, c.created_at,
           p.id, p.nom, p.prenom, p.ville_base
      from public.candidatures c
      join public.profiles p on p.id = c.pharmacien_id
     where c.contrat_id = p_contrat
     order by c.created_at;
end;
$$;
revoke all on function public.get_candidats(uuid) from public, anon;
grant execute on function public.get_candidats(uuid) to authenticated;

-- =====================================================================
-- RPC · accepter_candidature — un geste atomique :
-- candidature → accepte · contrat → attribue · autres → refuse
-- =====================================================================
create or replace function public.accepter_candidature(p_candidature uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_contrat uuid;
begin
  select c.contrat_id into v_contrat
    from public.candidatures c
    join public.contrats k on k.id = c.contrat_id
   where c.id = p_candidature
     and (k.pharmacie_id = auth.uid() or public.est_admin())
     and k.statut = 'ouvert';
  if v_contrat is null then
    raise exception 'Candidature introuvable ou contrat non ouvert';
  end if;

  update public.candidatures set statut = 'accepte' where id = p_candidature;
  update public.candidatures set statut = 'refuse'
   where contrat_id = v_contrat and id <> p_candidature
     and statut in ('propose','contre_offre');
  update public.contrats set statut = 'attribue' where id = v_contrat;
end;
$$;
revoke all on function public.accepter_candidature(uuid) from public, anon;
grant execute on function public.accepter_candidature(uuid) to authenticated;
