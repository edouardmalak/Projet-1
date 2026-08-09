-- =====================================================================
-- C-DIRECT · SQL 64 — Admin : réactiver / désactiver un compte
--
-- CONTEXTE (2026-08-09) : `desactiver_mon_compte()` (sql/49) est à SENS
-- UNIQUE — un usager peut désactiver son propre compte, mais RIEN ni
-- personne (pas même l'admin) ne pouvait le réactiver. Découvert en test.
-- On ajoute deux RPC admin-only + on expose l'état de désactivation dans
-- la fiche admin (get_profil_detail) pour que le bouton sache quoi montrer.
--
-- Les triggers anti-escalade (sql/01 rôle, sql/12 approbation) ne touchent
-- PAS `compte_desactive`, donc ces UPDATE passent sans les désactiver.
--
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Réactiver un compte désactivé
-- ---------------------------------------------------------------------
create or replace function public.admin_reactiver_compte(p_profil uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  update public.profiles
     set compte_desactive = false, compte_desactive_le = null
   where id = p_profil;
end; $$;
revoke all on function public.admin_reactiver_compte(uuid) from public, anon;
grant execute on function public.admin_reactiver_compte(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2) Désactiver un compte (symétrie — l'admin peut suspendre un compte
--    sans avoir à se connecter comme l'usager)
-- ---------------------------------------------------------------------
create or replace function public.admin_desactiver_compte(p_profil uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  update public.profiles
     set compte_desactive = true, compte_desactive_le = now()
   where id = p_profil;
  delete from public.push_subscriptions where profil_id = p_profil;
end; $$;
revoke all on function public.admin_desactiver_compte(uuid) from public, anon;
grant execute on function public.admin_desactiver_compte(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3) get_profil_detail — ajoute compte_desactive + compte_desactive_le
--    au bout du tableau de retour (le changement de forme impose un DROP).
--    Reste identique à sql/29 sinon.
-- ---------------------------------------------------------------------
drop function if exists public.get_profil_detail(uuid);
create or replace function public.get_profil_detail(p_profil uuid)
returns table (
  id uuid, role text, statut_verification text, approuve boolean,
  verification_raison text, verification_maj_le timestamptz, verification_par_nom text,
  nom text, prenom text, courriel text, telephone text, sms_optin boolean, cree_le timestamptz,
  numero_opq text, ville_base text, code_postal text,
  nom_pharmacie text, neq text, banniere text, adresse text, ville text,
  contact_proprietaire text, cell_proprietaire text,
  mandats_completes bigint, mandats_annules bigint, mandats_total bigint, taux_completion int,
  contrats_publies bigint, contrats_pourvus bigint, contrats_annules bigint,
  compte_desactive boolean, compte_desactive_le timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select p.id, p.role, p.statut_verification, p.approuve,
           p.verification_raison, p.verification_maj_le,
           nullif(trim(coalesce(v.prenom,'') || ' ' || coalesce(v.nom,'')), ''),
           p.nom, p.prenom, p.courriel, p.telephone, p.sms_optin, p.created_at,
           p.numero_opq, p.ville_base, p.code_postal,
           p.nom_pharmacie, p.neq, p.banniere, p.adresse, p.ville,
           p.contact_proprietaire, p.cell_proprietaire,
           case when p.role = 'pharmacien' then s.completes else null end,
           case when p.role = 'pharmacien' then s.annulations else null end,
           case when p.role = 'pharmacien' then s.total else null end,
           case when p.role = 'pharmacien' then s.taux_completion else null end,
           case when p.role = 'pharmacie' then
             (select count(*) from public.contrats k where k.pharmacie_id = p.id) else null end,
           case when p.role = 'pharmacie' then
             (select count(*) from public.contrats k where k.pharmacie_id = p.id and k.statut in ('attribue','complete')) else null end,
           case when p.role = 'pharmacie' then
             (select count(*) from public.contrats k where k.pharmacie_id = p.id and k.statut = 'annule') else null end,
           coalesce(p.compte_desactive, false), p.compte_desactive_le
      from public.profiles p
      left join public.profiles v on v.id = p.verification_par
      left join lateral public.get_stats_pharmacien(p.id) s on p.role = 'pharmacien'
     where p.id = p_profil;
end;
$$;
revoke all on function public.get_profil_detail(uuid) from public, anon;
grant execute on function public.get_profil_detail(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Réactivation immédiate du compte de test désactivé pendant les tests :
-- ---------------------------------------------------------------------
update public.profiles set compte_desactive = false, compte_desactive_le = null
 where courriel = 'edouardmalak+pharmacien@gmail.com';
