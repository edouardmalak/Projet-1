-- =====================================================================
-- C-DIRECT · SQL 27 — SUIVI DES COMMUNICATIONS (Zone Admin E)
-- À exécuter dans Supabase → SQL Editor, APRÈS 26-gestion-contrats.sql.
-- Idempotent (create or replace).
--
-- Lecture seule — aucune table modifiée. Le Worker c-direct-sms garde
-- l'entière propriété de l'envoi (service_role, hors RLS) ; ces RPC ne
-- font qu'exposer sms_queue et les désabonnements à la console admin.
-- =====================================================================

-- ---------------------------------------------------------------------
-- get_sms_queue — file d'attente (sms_queue), avec nom du destinataire
-- et un drapeau « en retard » (aurait dû partir mais est toujours en
-- attente — signal de panne du Worker/Cron, pas juste un envoi différé
-- aux heures de silence).
-- ---------------------------------------------------------------------
create or replace function public.get_sms_queue(p_limite int default 200)
returns table (
  id uuid, statut text, type text, to_number text, ville text,
  profile_id uuid, profil_nom text,
  envoyer_apres timestamptz, en_retard boolean, batch_id uuid,
  cree_le timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select q.id, q.statut, q.type, q.to_number, q.ville,
           q.profile_id, nullif(trim(coalesce(p.prenom,'') || ' ' || coalesce(p.nom,'')), ''),
           q.envoyer_apres,
           (q.statut = 'attente' and q.envoyer_apres < now()),
           q.batch_id, q.created_at
      from public.sms_queue q
      left join public.profiles p on p.id = q.profile_id
     order by
       case q.statut when 'attente' then 0 when 'envoi' then 1 else 2 end,
       q.envoyer_apres asc
     limit greatest(1, least(coalesce(p_limite, 200), 1000));
end;
$$;
revoke all on function public.get_sms_queue(int) from public, anon;
grant execute on function public.get_sms_queue(int) to authenticated;

-- ---------------------------------------------------------------------
-- get_opt_outs — pharmacien(ne)s actuellement supprimés des diffusions
-- (sms_optin = false), avec le dernier évènement de désabonnement connu
-- (mot-clé STOP/ARRÊT reçu, ou désabonnement posé autrement).
-- ---------------------------------------------------------------------
create or replace function public.get_opt_outs()
returns table (
  profile_id uuid, nom text, courriel text, telephone text,
  optout_le timestamptz, optout_evenement text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select p.id, nullif(trim(coalesce(p.prenom,'') || ' ' || coalesce(p.nom,'')), ''),
           p.courriel, p.telephone,
           dernier.created_at, dernier.body
      from public.profiles p
      left join lateral (
        select l.created_at, l.body
          from public.sms_log l
         where l.type = 'optout' and (l.profile_id = p.id or l.to_number = p.telephone)
         order by l.created_at desc
         limit 1
      ) dernier on true
     where p.role = 'pharmacien' and p.sms_optin = false
     order by coalesce(dernier.created_at, p.created_at) desc;
end;
$$;
revoke all on function public.get_opt_outs() from public, anon;
grant execute on function public.get_opt_outs() to authenticated;
