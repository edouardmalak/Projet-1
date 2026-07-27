-- =====================================================================
-- C-DIRECT · SQL 25 — FILE DE VÉRIFICATION (Zone Admin A)
-- À exécuter dans Supabase → SQL Editor, APRÈS 24-admin-audit.sql.
-- Idempotent (create or replace / if not exists).
--
-- Objet : remplacer le simple booléen profiles.approuve (vrai/faux) par
-- un vrai statut de vérification à 4 valeurs, avec raison et horodatage
-- « qui / quand », journalisé dans admin_audit_log (SQL 24).
--
--   en_attente → jamais examiné (nouvelle inscription)
--   verifie    → approuvé par un admin (équivaut à l'ancien approuve=true)
--   rejete     → refusé par un admin (jamais approuvé)
--   suspendu   → était vérifié, mis en pause par un admin
--
-- profiles.approuve reste la VRAIE barrière RLS (aucun changement aux
-- policies existantes) — il est simplement maintenu en synchronisation :
-- approuve = true SEULEMENT quand statut_verification = 'verifie'.
--
-- Défensif : tant que ce fichier n'est pas exécuté, la nouvelle page
-- admin-verification.html affiche une erreur claire — rien ne casse
-- ailleurs (la validation/révocation à l'ancienne reste fonctionnelle
-- tant que ce fichier n'est pas appliqué, car admin.html teste l'erreur).
-- =====================================================================

alter table public.profiles
  add column if not exists statut_verification text
    not null default 'en_attente'
    check (statut_verification in ('en_attente','verifie','rejete','suspendu')),
  add column if not exists verification_raison text,
  add column if not exists verification_maj_le timestamptz,
  add column if not exists verification_par uuid references public.profiles(id);

-- Rétro-remplissage à partir de l'état actuel (une seule fois, sans écraser
-- un statut déjà posé si ce fichier est réexécuté) :
update public.profiles
   set statut_verification = 'verifie',
       verification_maj_le = coalesce(verification_maj_le, approuve_date, created_at)
 where approuve = true and statut_verification = 'en_attente';

-- ---------------------------------------------------------------------
-- admin_maj_verification — point d'écriture UNIQUE du statut de
-- vérification. Garde profiles.approuve synchronisé (vraie barrière RLS)
-- et journalise systématiquement (admin_logger, SQL 24).
-- ---------------------------------------------------------------------
create or replace function public.admin_maj_verification(
  p_profil uuid, p_statut text, p_raison text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_nom text; v_role text; v_ancien text;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_statut not in ('en_attente','verifie','rejete','suspendu') then
    raise exception 'Statut invalide : %', p_statut;
  end if;
  if p_statut in ('rejete','suspendu') and (p_raison is null or length(trim(p_raison)) < 3) then
    raise exception 'Raison obligatoire (min. 3 caractères) pour rejeter ou suspendre';
  end if;

  select statut_verification into v_ancien from public.profiles where id = p_profil;
  if v_ancien is null then raise exception 'Profil introuvable'; end if;

  update public.profiles
     set statut_verification = p_statut,
         verification_raison = p_raison,
         verification_maj_le = now(),
         verification_par = auth.uid(),
         approuve = (p_statut = 'verifie'),
         approuve_date = case when p_statut = 'verifie' then now() else null end
   where id = p_profil
  returning role, coalesce(nom_pharmacie, nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), courriel)
    into v_role, v_nom;

  perform public.admin_logger(
    'verification_maj', 'profile', p_profil::text,
    jsonb_build_object('nom', v_nom, 'role', v_role, 'de', v_ancien, 'vers', p_statut, 'raison', p_raison)
  );
end;
$$;
revoke all on function public.admin_maj_verification(uuid, text, text) from public, anon;
grant execute on function public.admin_maj_verification(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- get_file_verification — la file d'admin : tous les comptes non-admin,
-- avec les champs de vérification propres à chaque rôle et un indicateur
-- simple de complétude de profil (X / Y champs clés remplis).
-- ---------------------------------------------------------------------
create or replace function public.get_file_verification()
returns table (
  id uuid, role text, statut_verification text,
  nom text, prenom text, courriel text, telephone text,
  numero_opq text, ville_base text,
  nom_pharmacie text, neq text, banniere text, adresse text, ville text, code_postal text,
  contact_proprietaire text,
  champs_remplis int, champs_total int,
  verification_raison text, verification_maj_le timestamptz, verification_par_nom text,
  cree_le timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select p.id, p.role, p.statut_verification,
           p.nom, p.prenom, p.courriel, p.telephone,
           p.numero_opq, p.ville_base,
           p.nom_pharmacie, p.neq, p.banniere, p.adresse, p.ville, p.code_postal,
           p.contact_proprietaire,
           case when p.role = 'pharmacien' then
             (case when p.nom is not null then 1 else 0 end +
              case when p.prenom is not null then 1 else 0 end +
              case when p.telephone is not null then 1 else 0 end +
              case when p.numero_opq is not null then 1 else 0 end +
              case when p.ville_base is not null then 1 else 0 end +
              case when p.code_postal is not null then 1 else 0 end)
           else
             (case when p.nom_pharmacie is not null then 1 else 0 end +
              case when p.neq is not null then 1 else 0 end +
              case when p.adresse is not null then 1 else 0 end +
              case when p.ville is not null then 1 else 0 end +
              case when p.code_postal is not null then 1 else 0 end +
              case when p.banniere is not null then 1 else 0 end +
              case when p.telephone is not null then 1 else 0 end)
           end,
           case when p.role = 'pharmacien' then 6 else 7 end,
           p.verification_raison, p.verification_maj_le,
           nullif(trim(coalesce(v.prenom,'') || ' ' || coalesce(v.nom,'')), ''),
           p.created_at
      from public.profiles p
      left join public.profiles v on v.id = p.verification_par
     where p.role in ('pharmacien','pharmacie')
     order by
       case p.statut_verification when 'en_attente' then 0 else 1 end,
       p.created_at desc;
end;
$$;
revoke all on function public.get_file_verification() from public, anon;
grant execute on function public.get_file_verification() to authenticated;
