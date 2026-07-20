-- =====================================================================
-- C-DIRECT · SQL 15 — Préférence de langue + confirmation de contrat
-- À exécuter dans Supabase → SQL Editor (idempotent).
--
-- 1) profiles.langue ('fr' par défaut, 'en' possible) — choisie au profil.
-- 2) À l'acceptation d'une candidature, la confirmation « contrat confirmé »
--    (courriel bilingue + PDF joint) est désormais envoyée par le Worker
--    c-direct-sms (via le webhook candidatures UPDATE). On RETIRE donc la
--    branche 'accepte' de l'ancien trigger courriel pour éviter les doublons.
--    Les courriels contre-offre et refus (manuel) restent inchangés.
--
-- Pré-requis côté Worker : ajouter le secret RESEND_API_KEY (et au besoin
--   RESEND_FROM) puis redéployer :  npx wrangler secret put RESEND_API_KEY
-- =====================================================================

alter table public.profiles
  add column if not exists langue text not null default 'fr'
  check (langue in ('fr','en'));

-- Trigger courriel candidatures : version SANS la branche 'accepte'
create or replace function public.notifier_maj_candidature()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_contrat public.contrats%rowtype;
  v_pharmacien public.profiles%rowtype;
  v_dernier_jalon jsonb;
  v_auto boolean;
begin
  if new.statut = old.statut then return new; end if;

  select * into v_contrat from public.contrats where id = new.contrat_id;
  select * into v_pharmacien from public.profiles where id = new.pharmacien_id;

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

  -- 'accepte' : la confirmation (courriel bilingue + PDF) est envoyée par
  -- le Worker c-direct-sms. Aucun courriel ici pour éviter les doublons.

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
