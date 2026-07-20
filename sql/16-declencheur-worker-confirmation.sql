-- =====================================================================
-- C-DIRECT · SQL 16 — Déclencheur direct : acceptation → Worker
-- À exécuter dans Supabase → SQL Editor (idempotent, sans danger).
--
-- Pourquoi : les "Database Webhooks" du tableau de bord ne délivraient pas
-- l'évènement d'acceptation au Worker (aucune trace dans sms_log). Ce
-- déclencheur appelle le Worker DIRECTEMENT via pg_net, avec le même
-- format de charge utile que les webhooks. Résultat : à chaque acceptation
--   → SMS d'attribution + courriel « contrat confirmé » avec PDF joint.
--
-- Sécurité : l'appel réseau est enveloppé — s'il échoue, l'acceptation
-- réussit quand même (jamais bloquant). Le Worker déduplique déjà les
-- doublons (fenêtre 10 min), donc coexiste sans risque avec un webhook.
-- Pré-requis : pg_net actif (déjà installé), et le secret RESEND_API_KEY
-- dans le Worker (fait) pour l'envoi du courriel.
-- =====================================================================

create extension if not exists pg_net;

create or replace function public.pinger_worker_confirmation()
returns trigger
language plpgsql
security definer
set search_path = public, net, extensions
as $$
begin
  if new.statut = 'accepte' and old.statut is distinct from 'accepte' then
    begin
      perform net.http_post(
        url     := 'https://c-direct-sms.edouardmalak.workers.dev/webhook',
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'X-Webhook-Secret', '62fec5c4c01c77530a4c8e628f72b0e961353477a392895641b7896de27b95a4'),
        body    := jsonb_build_object(
                     'type', 'UPDATE',
                     'table', 'candidatures',
                     'record', to_jsonb(new),
                     'old_record', to_jsonb(old))
      );
    exception when others then
      -- ne JAMAIS casser l'acceptation si le ping réseau échoue
      raise notice 'pinger_worker_confirmation: appel Worker échoué: %', sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pinger_worker_confirmation on public.candidatures;
create trigger trg_pinger_worker_confirmation
  after update of statut on public.candidatures
  for each row execute function public.pinger_worker_confirmation();

-- Vérification (facultatif) : après avoir accepté un contrat OUVERT, la
-- réponse du Worker apparaît dans :
--   select * from net._http_response order by created desc limit 3;
