-- =====================================================================
-- C-DIRECT · SQL 12 — VALIDATION DES COMPTES PAR L'ADMINISTRATEUR
-- À exécuter APRÈS 11-sms-queue.sql, dans Supabase → SQL Editor.
--
-- Problème corrigé : un compte devenait pleinement actif dès la
-- confirmation du courriel, SANS intervention de l'admin. Désormais :
--   · profiles.approuve (false par défaut) — seul un admin peut le changer
--   · publier un contrat (pharmacie) et postuler (pharmacien) exigent
--     l'approbation AU NIVEAU DE LA BASE (RLS), pas seulement en interface
--   · les comptes non approuvés sont redirigés vers /attente.html
-- =====================================================================

alter table public.profiles add column if not exists approuve boolean not null default false;
alter table public.profiles add column if not exists approuve_date timestamptz;

-- les admins sont approuvés d'office (les autres comptes existants
-- restent « en attente » — à valider dans la console admin)
update public.profiles set approuve = true, approuve_date = now()
 where role = 'admin' and approuve = false;

-- ---------------------------------------------------------------------
-- Helper : le compte courant est-il approuvé ? (admin toujours oui)
-- ---------------------------------------------------------------------
create or replace function public.est_approuve()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from public.profiles
                  where id = auth.uid() and (approuve = true or role = 'admin'));
$$;

-- ---------------------------------------------------------------------
-- ANTI-ESCALADE : seul un admin peut modifier approuve / approuve_date
-- (profiles_update_soi permet à chacun de modifier SA ligne — sans ce
-- trigger, un utilisateur pourrait s'auto-approuver).
-- ---------------------------------------------------------------------
create or replace function public.empecher_changement_approbation()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if (new.approuve is distinct from old.approuve
      or new.approuve_date is distinct from old.approuve_date)
     and not public.est_admin() then
    raise exception 'Validation du compte réservée à l''administrateur';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_empecher_approbation on public.profiles;
create trigger trg_empecher_approbation
  before update on public.profiles
  for each row execute function public.empecher_changement_approbation();

-- ---------------------------------------------------------------------
-- RLS : les gestes clés exigent l'approbation (défense en profondeur —
-- l'interface bloque aussi, mais la base est la vraie barrière).
-- ---------------------------------------------------------------------
drop policy if exists "contrats_insert" on public.contrats;
create policy "contrats_insert" on public.contrats for insert with check (
  public.est_admin()
  or (pharmacie_id = auth.uid()
      and public.mon_role() = 'pharmacie'
      and public.est_approuve())
);

drop policy if exists "candidatures_insert" on public.candidatures;
create policy "candidatures_insert" on public.candidatures for insert with check (
  public.est_admin()
  or (
    pharmacien_id = auth.uid()
    and public.mon_role() = 'pharmacien'
    and public.contrat_est_ouvert(contrat_id)
    and public.est_approuve()
  )
);
