-- =====================================================================
-- C-DIRECT · SQL 21 — BLOCAGES / EXCLUSIONS (pharmacien ↔ pharmacie)
-- À exécuter dans Supabase → SQL Editor, APRÈS 20-profil-enrichi.sql.
-- Idempotent (create or replace / if not exists).
--
-- Objet : l'admin peut « séparer » une pharmacie et un pharmacien en cas
-- de problème. Le blocage est MUTUEL : une seule ligne suffit —
--   • le pharmacien ne voit plus les affichages de cette pharmacie
--     (ni le tableau, ni la fiche du contrat) et NE PEUT PLUS y postuler ;
--   • la pharmacie ne voit plus les candidatures de ce pharmacien.
-- Seul un admin peut créer/retirer un blocage (RLS).
--
-- Défensif : tant que ce fichier n'est pas exécuté, l'interface admin
-- s'affiche mais l'ajout/lecture des blocages renverra une erreur claire.
-- Une fois exécuté, tout s'active — aucune autre étape.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Table des exclusions (clé = la paire ; le blocage est donc unique et mutuel)
-- ---------------------------------------------------------------------
create table if not exists public.exclusions (
  pharmacien_id uuid not null references public.profiles(id) on delete cascade,
  pharmacie_id  uuid not null references public.profiles(id) on delete cascade,
  raison        text,
  cree_par      uuid references public.profiles(id),
  created_at    timestamptz not null default now(),
  primary key (pharmacien_id, pharmacie_id)
);

alter table public.exclusions enable row level security;

-- RLS : admin uniquement (lecture + écriture). Les RPC security definer
-- ci-dessous lisent la table indépendamment de la RLS.
drop policy if exists exclusions_admin_all on public.exclusions;
create policy exclusions_admin_all on public.exclusions
  for all using (public.est_admin()) with check (public.est_admin());

-- ---------------------------------------------------------------------
-- Helper : la paire (pharmacien, pharmacie) est-elle bloquée ?
-- ---------------------------------------------------------------------
create or replace function public.est_exclu(p_pharmacien uuid, p_pharmacie uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.exclusions e
     where e.pharmacien_id = p_pharmacien
       and e.pharmacie_id  = p_pharmacie
  );
$$;
revoke all on function public.est_exclu(uuid, uuid) from public, anon;
grant execute on function public.est_exclu(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- get_contrats_ouverts — tableau du pharmacien : on masque les contrats
-- des pharmacies bloquées pour lui. (reprend SQL 13 + filtre exclusion)
-- ---------------------------------------------------------------------
drop function if exists public.get_contrats_ouverts();
create or replace function public.get_contrats_ouverts()
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  statut text, ville text, logiciel text, code_postal text, deja_postule boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (public.mon_role() in ('pharmacien','admin')) then
    raise exception 'Accès refusé';
  end if;
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.statut, p.ville, p.logiciel, p.code_postal,
           exists (select 1 from public.candidatures c
                    where c.contrat_id = k.id and c.pharmacien_id = auth.uid())
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.statut = 'ouvert'
       -- l'admin voit tout ; le pharmacien ne voit pas les pharmacies bloquées
       and (public.est_admin() or not public.est_exclu(auth.uid(), k.pharmacie_id))
     order by k.created_at desc;
end;
$$;
revoke all on function public.get_contrats_ouverts() from public, anon;
grant execute on function public.get_contrats_ouverts() to authenticated;

-- ---------------------------------------------------------------------
-- get_contrat_fiche — un pharmacien bloqué ne peut plus ouvrir la fiche
-- d'un contrat de cette pharmacie. (reprend SQL 13 + filtre exclusion)
-- ---------------------------------------------------------------------
drop function if exists public.get_contrat_fiche(text);
create or replace function public.get_contrat_fiche(p_ref text)
returns table (
  id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time, tarif_horaire numeric,
  rx_jour_semaine int, rx_jour_weekend int,
  seul_pharmacien boolean, atp_presente boolean, services text[],
  notes text, statut text, created_at timestamptz,
  ville text, logiciel text, code_postal text,
  ma_candidature_statut text, est_ma_pharmacie boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select k.id, k.numero_reference, k.date_contrat,
           k.heure_debut, k.heure_fin, k.tarif_horaire,
           k.rx_jour_semaine, k.rx_jour_weekend,
           k.seul_pharmacien, k.atp_presente, k.services,
           k.notes, k.statut, k.created_at,
           p.ville, p.logiciel, p.code_postal,
           (select c.statut from public.candidatures c
             where c.contrat_id = k.id and c.pharmacien_id = auth.uid()),
           (k.pharmacie_id = auth.uid())
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.numero_reference = upper(trim(p_ref))
       and (
         public.est_admin()
         or k.pharmacie_id = auth.uid()
         or (public.mon_role() = 'pharmacien'
             and (k.statut = 'ouvert' or public.a_postule(k.id))
             and not public.est_exclu(auth.uid(), k.pharmacie_id))
       );
end;
$$;
revoke all on function public.get_contrat_fiche(text) from public, anon;
grant execute on function public.get_contrat_fiche(text) to authenticated;

-- ---------------------------------------------------------------------
-- get_candidats — la pharmacie ne voit plus les candidatures d'un
-- pharmacien bloqué (l'admin, lui, continue de tout voir pour arbitrer).
-- (reprend SQL 20 v3 + join contrats + filtre exclusion)
-- ---------------------------------------------------------------------
drop function if exists public.get_candidats(uuid);
create function public.get_candidats(p_contrat uuid)
returns table (
  candidature_id uuid, statut text, type_candidature text,
  tarif_propose numeric, heure_debut_proposee time, heure_fin_proposee time,
  distance_km numeric, message text,
  cree_le timestamptz, maj_le timestamptz,
  pharmacien_id uuid, nom text, prenom text, ville_base text,
  logiciels text[], competences text[], langues_parlees text[],
  note_moyenne numeric, note_nombre bigint
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
    select c.id, c.statut, c.type_candidature,
           c.tarif_propose, c.heure_debut_proposee, c.heure_fin_proposee,
           c.distance_km, c.message,
           c.created_at, c.updated_at,
           p.id, p.nom, p.prenom, p.ville_base,
           p.logiciels, p.competences, p.langues_parlees,
           (select g.moyenne from public.get_note_profil(p.id) g),
           (select g.nombre  from public.get_note_profil(p.id) g)
      from public.candidatures c
      join public.profiles p on p.id = c.pharmacien_id
      join public.contrats  k on k.id = c.contrat_id
     where c.contrat_id = p_contrat
       and (public.est_admin() or not public.est_exclu(c.pharmacien_id, k.pharmacie_id))
     order by c.created_at;
end;
$$;
revoke all on function public.get_candidats(uuid) from public, anon;
grant execute on function public.get_candidats(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Garde-fou : un pharmacien bloqué ne peut pas insérer de candidature
-- sur un contrat de cette pharmacie (même s'il a l'URL/la référence).
-- ---------------------------------------------------------------------
create or replace function public.bloquer_candidature_exclue()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if public.est_exclu(new.pharmacien_id,
       (select pharmacie_id from public.contrats where id = new.contrat_id)) then
    raise exception 'Candidature refusée : cette pharmacie n''est pas accessible.';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_bloquer_candidature_exclue on public.candidatures;
create trigger trg_bloquer_candidature_exclue
  before insert on public.candidatures
  for each row execute function public.bloquer_candidature_exclue();

-- ---------------------------------------------------------------------
-- admin_lister_exclusions — liste lisible (noms) pour la console admin
-- ---------------------------------------------------------------------
create or replace function public.admin_lister_exclusions()
returns table (
  pharmacien_id uuid, pharmacie_id uuid, raison text, created_at timestamptz,
  pharmacien_nom text, pharmacie_nom text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select e.pharmacien_id, e.pharmacie_id, e.raison, e.created_at,
           nullif(trim(coalesce(pn.prenom,'') || ' ' || coalesce(pn.nom,'')), ''),
           coalesce(nullif(pe.nom_pharmacie,''),
                    nullif(trim(coalesce(pe.prenom,'') || ' ' || coalesce(pe.nom,'')), ''))
      from public.exclusions e
      join public.profiles pn on pn.id = e.pharmacien_id
      join public.profiles pe on pe.id = e.pharmacie_id
     order by e.created_at desc;
end;
$$;
revoke all on function public.admin_lister_exclusions() from public, anon;
grant execute on function public.admin_lister_exclusions() to authenticated;
