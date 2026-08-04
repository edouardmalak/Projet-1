-- =====================================================================
-- C-DIRECT · PAIEMENTS · SQL 47 — COURRIEL INTERAC VÉRIFIÉ + VERROUILLÉ
-- À exécuter APRÈS sql/46-relance-paliers.sql, dans Supabase → SQL Editor.
--
-- Contrôle anti-fraude du skill c-direct-payments (§ Fraud controls) :
-- « the autodeposit email is locked. Verified by token at onboarding;
-- any change triggers a 72-hour cooling-off plus SMS confirmation to the
-- phone on file, and no payment instruction is issued for any shift in
-- that window — those route to card. »
--
-- Avant ce fichier, facture-vue.html affichait le courriel de CONNEXION
-- du pharmacien (profiles.courriel) comme destination Interac — sans
-- aucune vérification. Un compte compromis pouvait donc rediriger un
-- paiement en changeant simplement le courriel du profil. Ce fichier
-- sépare complètement les deux : courriel_interac est un champ distinct,
-- vérifié par code à 6 chiffres, et tout CHANGEMENT (pas la 1re fois)
-- déclenche un délai de 72h pendant lequel l'ancienne adresse reste
-- affichée... non — pendant lequel AUCUNE instruction Interac n'est
-- affichée du tout (on bascule sur le message "carte de garantie"),
-- pour ne jamais risquer d'envoyer vers une adresse encore invérifiée.
-- =====================================================================

alter table public.profiles
  add column if not exists courriel_interac text,
  add column if not exists courriel_interac_verifie boolean not null default false,
  add column if not exists courriel_interac_deja_verifie_une_fois boolean not null default false,
  add column if not exists courriel_interac_code text,
  add column if not exists courriel_interac_code_expire timestamptz,
  add column if not exists courriel_interac_cooldown_jusqua timestamptz;

comment on column public.profiles.courriel_interac_deja_verifie_une_fois is
  'Reste TRUE pour toujours dès la 1re vérification réussie — sert à
   distinguer « premier réglage » (pas de délai) de « changement »
   (délai de 72h) dans confirmer_courriel_interac(). Ne jamais remettre
   à false, même si courriel_interac_verifie repasse à false pendant
   une nouvelle vérification en cours.';

-- ---------------------------------------------------------------------
-- RPC · demarrer_verification_courriel_interac — pharmacien saisit/
-- change son adresse ; génère un code à 6 chiffres (15 min de validité).
-- L'envoi du courriel lui-même se fait via le Worker c-direct-sms
-- (POST /pharmacien/envoyer-code-interac, Resend) — cette RPC ne fait
-- QUE l'état, jamais d'appel externe.
-- ---------------------------------------------------------------------
create or replace function public.demarrer_verification_courriel_interac(p_email text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_role text;
  v_code text;
begin
  select role into v_role from public.profiles where id = auth.uid();
  if v_role is distinct from 'pharmacien' then
    raise exception 'Réservé aux pharmaciens';
  end if;
  if p_email is null or p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Courriel invalide';
  end if;

  v_code := lpad(floor(random() * 1000000)::text, 6, '0');

  update public.profiles
     set courriel_interac = lower(trim(p_email)),
         courriel_interac_verifie = false,
         courriel_interac_code = v_code,
         courriel_interac_code_expire = now() + interval '15 minutes'
   where id = auth.uid();
end;
$$;
revoke all on function public.demarrer_verification_courriel_interac(text) from public, anon;
grant execute on function public.demarrer_verification_courriel_interac(text) to authenticated;

-- ---------------------------------------------------------------------
-- RPC · confirmer_courriel_interac — vérifie le code. Retourne TRUE si
-- c'était un CHANGEMENT (délai de 72h appliqué, le Worker doit envoyer
-- le SMS d'alerte), FALSE si c'était le tout premier réglage (actif
-- immédiatement, rien à retarder).
-- ---------------------------------------------------------------------
create or replace function public.confirmer_courriel_interac(p_code text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  p public.profiles%rowtype;
  v_est_changement boolean;
begin
  select * into p from public.profiles where id = auth.uid();
  if not found then raise exception 'Profil introuvable'; end if;
  if p.courriel_interac_code is null or p.courriel_interac_code_expire is null or p.courriel_interac_code_expire < now() then
    raise exception 'Code expiré — redemandez-en un';
  end if;
  if p.courriel_interac_code is distinct from trim(p_code) then
    raise exception 'Code incorrect';
  end if;

  v_est_changement := p.courriel_interac_deja_verifie_une_fois;

  update public.profiles
     set courriel_interac_verifie = true,
         courriel_interac_deja_verifie_une_fois = true,
         courriel_interac_code = null,
         courriel_interac_code_expire = null,
         courriel_interac_cooldown_jusqua = case when v_est_changement then now() + interval '72 hours' else null end
   where id = auth.uid();

  return v_est_changement;
end;
$$;
revoke all on function public.confirmer_courriel_interac(text) from public, anon;
grant execute on function public.confirmer_courriel_interac(text) to authenticated;

-- ---------------------------------------------------------------------
-- get_factures() — RECRÉÉE (forme de retour changée) : ajoute le
-- courriel Interac VÉRIFIÉ (distinct du courriel de connexion) + son
-- statut, pour que facture-vue.html sache s'il est sûr de l'afficher.
-- pharmacien_courriel (connexion) reste renvoyé pour compat (email de
-- contact générique), mais n'est PLUS utilisé comme destination Interac
-- côté front — voir facture-vue.html.
-- ---------------------------------------------------------------------
drop function if exists public.get_factures();
create function public.get_factures()
returns table (
  facture_id uuid, numero_facture int, type_facture text, statut text,
  heures numeric, tarif_horaire numeric, km numeric, taux_km numeric,
  per_diem_montant numeric, hebergement_montant numeric, total numeric,
  date_envoi timestamptz, date_paiement timestamptz, date_echeance date,
  cree_le timestamptz,
  candidature_id uuid, contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time,
  pharmacien_id uuid, pharmacien_prenom text, pharmacien_nom text,
  pharmacien_opq text, pharmacien_courriel text,
  pharmacie_id uuid, nom_pharmacie text, pharmacie_adresse text,
  pharmacie_ville text, pharmacie_cp text, pharmacie_neq text, pharmacie_courriel text,
  pharmacien_societe text, pharmacien_tps text, pharmacien_tvq text,
  pharmacien_courriel_interac text, pharmacien_courriel_interac_verifie boolean,
  pharmacien_courriel_interac_cooldown timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select f.id, f.numero_facture, f.type_facture, f.statut,
           f.heures, f.tarif_horaire, f.km, f.taux_km,
           f.per_diem_montant, f.hebergement_montant, f.total,
           f.date_envoi, f.date_paiement, f.date_echeance,
           f.created_at,
           c.id, k.id, k.numero_reference, k.date_contrat,
           coalesce(c.heure_debut_proposee, k.heure_debut),
           coalesce(c.heure_fin_proposee,  k.heure_fin),
           pn.id, pn.prenom, pn.nom, pn.numero_opq, pn.courriel,
           pe.id, pe.nom_pharmacie, pe.adresse, pe.ville, pe.code_postal, pe.neq, pe.courriel,
           pn.societe, pn.tps, pn.tvq,
           pn.courriel_interac, pn.courriel_interac_verifie, pn.courriel_interac_cooldown_jusqua
      from public.factures f
      join public.candidatures c on c.id = f.candidature_id
      join public.contrats k     on k.id = c.contrat_id
      join public.profiles pn    on pn.id = c.pharmacien_id
      join public.profiles pe    on pe.id = k.pharmacie_id
     where public.est_admin()
        or c.pharmacien_id = auth.uid()
        or k.pharmacie_id = auth.uid()
     order by f.created_at desc;
end;
$$;
revoke all on function public.get_factures() from public, anon;
grant execute on function public.get_factures() to authenticated;

-- Vérification : select courriel_interac, courriel_interac_verifie from public.profiles where role='pharmacien' limit 3;
