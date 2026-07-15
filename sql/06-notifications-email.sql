-- =====================================================================
-- C-DIRECT · PHASE 2.3 — VRAIS COURRIELS PAR UTILISATEUR (Resend)
-- À exécuter APRÈS 05-negociation.sql, dans Supabase → SQL Editor.
--
-- POURQUOI CE FICHIER EXISTE
-- Le correctif déployé dans contrat.html (cdAlerteAdmin, voir outils.js)
-- n'envoie qu'UNE alerte à Robert via Web3Forms — une clé Web3Forms
-- livre toujours à la même boîte, elle ne peut pas notifier
-- dynamiquement le pharmacien ou la pharmacie eux-mêmes. Ce fichier
-- met en place la vraie solution : un webhook base de données qui
-- envoie un courriel CIBLÉ (au bon destinataire) à chaque évènement
-- de candidature, via l'API Resend (https://resend.com).
--
-- CE QU'IL FAUT FAIRE AVANT D'EXÉCUTER CE FICHIER (une seule fois) :
--   1. Créer un compte gratuit sur https://resend.com (100 courriels/jour,
--      3000/mois gratuits — largement suffisant pour le lancement).
--   2. Ajouter et vérifier un domaine d'envoi (Resend → Domains → Add
--      Domain) : quelques enregistrements DNS (SPF/DKIM) chez votre
--      registraire. SANS domaine vérifié, Resend n'autorise l'envoi de
--      test qu'à VOTRE PROPRE adresse (edouardmalak@gmail.com) — donc
--      les courriels aux pharmaciens/pharmacies ne partiront pas tant
--      qu'un domaine n'est pas vérifié. C'est une limite du service,
--      pas un bug de ce script.
--   3. Créer une clé API (Resend → API Keys → Create API Key).
--   4. Stocker la clé dans Supabase Vault (JAMAIS en clair dans le SQL,
--      jamais côté client) — exécuter séparément AVANT ce fichier :
--         select vault.create_secret('re_VOTRE_CLE_ICI', 'resend_api_key');
--      (Si déjà créé et à mettre à jour :
--         select vault.update_secret(
--           (select id from vault.decrypted_secrets where name = 'resend_api_key'),
--           'nouvelle_cle');)
--   5. FAIT : l'adresse d'expédition ci-dessous est déjà réglée sur
--      'notifications@c-direct.ca' (domaine c-direct.ca). Ce domaine DOIT
--      être vérifié dans Resend → Domains AVANT d'exécuter ce fichier,
--      sinon Resend rejettera tous les envois.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Extension pg_net : permet à Postgres de faire des appels HTTP sortants
-- (asynchrones — n'attend pas la réponse, donc ne ralentit jamais l'app).
-- ---------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------
-- Helper générique : envoyer un courriel via Resend.
-- Best-effort : si la clé n'est pas configurée, ou l'appel échoue,
-- ne bloque JAMAIS la transaction (candidature/mise à jour réussit
-- quand même) — juste pas de courriel envoyé.
-- ---------------------------------------------------------------------
create or replace function public.envoyer_email(p_a text, p_sujet text, p_html text)
returns void
language plpgsql security definer set search_path = public, extensions
as $$
declare v_cle text;
begin
  if p_a is null or p_a = '' then return; end if;

  select decrypted_secret into v_cle
    from vault.decrypted_secrets where name = 'resend_api_key';

  if v_cle is null then
    raise notice 'envoyer_email: clé resend_api_key absente du Vault — courriel non envoyé (à: %)', p_a;
    return;
  end if;

  perform extensions.net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_cle,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'C-Direct <notifications@c-direct.ca>',   -- domaine vérifié dans Resend
      'to', array[p_a],
      'subject', p_sujet,
      'html', p_html
    )
  );
exception when others then
  -- ne jamais faire échouer la candidature/mise à jour à cause d'un courriel
  raise notice 'envoyer_email: échec envoi à % — %', p_a, sqlerrm;
end;
$$;
revoke all on function public.envoyer_email(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Trigger : à l'INSERTION d'une candidature
--   → confirmation au pharmacien qui vient de postuler
--   → alerte à la pharmacie qu'une candidature est arrivée
-- ---------------------------------------------------------------------
create or replace function public.notifier_nouvelle_candidature()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_contrat public.contrats%rowtype;
  v_pharmacien public.profiles%rowtype;
  v_pharmacie public.profiles%rowtype;
  v_tarif text;
begin
  select * into v_contrat from public.contrats where id = new.contrat_id;
  select * into v_pharmacien from public.profiles where id = new.pharmacien_id;
  select * into v_pharmacie from public.profiles where id = v_contrat.pharmacie_id;
  v_tarif := to_char(new.tarif_propose, 'FM999999990.00') || ' $/h';

  -- confirmation au pharmacien
  perform public.envoyer_email(
    v_pharmacien.courriel,
    'Candidature envoyée — ' || v_contrat.numero_reference,
    '<p>Bonjour ' || coalesce(v_pharmacien.prenom, '') || ',</p>' ||
    '<p>Votre ' || (case when new.type_candidature = 'instantanee' then 'candidature au tarif affiché' else 'offre' end) ||
    ' (' || v_tarif || ') pour le contrat <b>' || v_contrat.numero_reference || '</b> a bien été envoyée à la pharmacie.</p>' ||
    '<p>Vous serez averti(e) par courriel dès que la pharmacie répond.</p>' ||
    '<p>— C-Direct</p>'
  );

  -- alerte à la pharmacie
  perform public.envoyer_email(
    v_pharmacie.courriel,
    'Nouvelle candidature — ' || v_contrat.numero_reference,
    '<p>Bonjour,</p>' ||
    '<p>' || coalesce(v_pharmacien.prenom || ' ' || v_pharmacien.nom, 'Un pharmacien') ||
    ' vient de postuler (' || v_tarif || ') sur votre contrat <b>' || v_contrat.numero_reference || '</b>.</p>' ||
    '<p>Connectez-vous à votre espace pharmacie pour accepter ou faire une contre-offre.</p>' ||
    '<p>— C-Direct</p>'
  );

  return new;
end;
$$;

drop trigger if exists trg_notifier_nouvelle_candidature on public.candidatures;
create trigger trg_notifier_nouvelle_candidature
  after insert on public.candidatures
  for each row execute function public.notifier_nouvelle_candidature();

-- ---------------------------------------------------------------------
-- Trigger : au CHANGEMENT DE STATUT d'une candidature
--   contre_offre → courriel au pharmacien (la pharmacie a contré)
--   accepte      → courriel au pharmacien ET à la pharmacie (entente conclue)
--   refuse (non automatique) → courriel au pharmacien
-- Les refus AUTOMATIQUES (les autres candidatures closes quand une est
-- acceptée — voir sql/05, ajouter_jalon 'auto',true) ne génèrent PAS de
-- courriel : ce ne serait que du bruit.
-- ---------------------------------------------------------------------
create or replace function public.notifier_maj_candidature()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_contrat public.contrats%rowtype;
  v_pharmacien public.profiles%rowtype;
  v_pharmacie public.profiles%rowtype;
  v_dernier_jalon jsonb;
  v_auto boolean;
begin
  if new.statut = old.statut then return new; end if;

  select * into v_contrat from public.contrats where id = new.contrat_id;
  select * into v_pharmacien from public.profiles where id = new.pharmacien_id;
  select * into v_pharmacie from public.profiles where id = v_contrat.pharmacie_id;

  begin
    v_dernier_jalon := (new.message::jsonb) -> -1;
  exception when others then
    v_dernier_jalon := null;
  end;
  v_auto := coalesce((v_dernier_jalon ->> 'auto')::boolean, false);

  if new.statut = 'contre_offre' then
    perform public.envoyer_email(
      v_pharmacien.courriel,
      'Contre-offre reçue — ' || v_contrat.numero_reference,
      '<p>Bonjour ' || coalesce(v_pharmacien.prenom, '') || ',</p>' ||
      '<p>La pharmacie vous a fait une contre-offre sur le contrat <b>' || v_contrat.numero_reference || '</b>.</p>' ||
      '<p>Connectez-vous pour l’accepter ou la refuser.</p>' ||
      '<p>— C-Direct</p>'
    );

  elsif new.statut = 'accepte' then
    perform public.envoyer_email(
      v_pharmacien.courriel,
      'Candidature acceptée — ' || v_contrat.numero_reference,
      '<p>Bonjour ' || coalesce(v_pharmacien.prenom, '') || ',</p>' ||
      '<p>Votre candidature pour le contrat <b>' || v_contrat.numero_reference || '</b> a été ACCEPTÉE. La pharmacie vous contactera pour les détails.</p>' ||
      '<p>— C-Direct</p>'
    );
    perform public.envoyer_email(
      v_pharmacie.courriel,
      'Contrat attribué — ' || v_contrat.numero_reference,
      '<p>Bonjour,</p>' ||
      '<p>Le contrat <b>' || v_contrat.numero_reference || '</b> a été attribué à ' ||
      coalesce(v_pharmacien.prenom || ' ' || v_pharmacien.nom, 'un pharmacien') || '.</p>' ||
      '<p>— C-Direct</p>'
    );

  elsif new.statut = 'refuse' and not v_auto then
    perform public.envoyer_email(
      v_pharmacien.courriel,
      'Candidature non retenue — ' || v_contrat.numero_reference,
      '<p>Bonjour ' || coalesce(v_pharmacien.prenom, '') || ',</p>' ||
      '<p>Votre candidature pour le contrat <b>' || v_contrat.numero_reference || '</b> n’a pas été retenue.</p>' ||
      '<p>— C-Direct</p>'
    );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_notifier_maj_candidature on public.candidatures;
create trigger trg_notifier_maj_candidature
  after update of statut on public.candidatures
  for each row execute function public.notifier_maj_candidature();

-- =====================================================================
-- VÉRIFICATION RAPIDE APRÈS DÉPLOIEMENT
-- 1. select vault.create_secret('re_xxx', 'resend_api_key');  (une fois)
-- 2. Postuler à un contrat test → vérifier dans Resend → Logs qu'un
--    envoi apparaît (statut "Sent" si domaine vérifié, ou l'erreur
--    exacte sinon — utile pour déboguer).
-- 3. select * from net._http_response order by created desc limit 5;
--    → inspecter le code retourné par l'appel pg_net le plus récent.
-- =====================================================================
