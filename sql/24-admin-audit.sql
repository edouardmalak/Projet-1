-- =====================================================================
-- C-DIRECT · SQL 24 — FONDATIONS ADMIN : JOURNAL D'AUDIT + RPC PRIVILÉGIÉS
-- À exécuter dans Supabase → SQL Editor, APRÈS 23-phase8.sql.
-- Idempotent (create or replace / if not exists).
--
-- Objet (Phase Admin · Zone G) :
--   · admin_audit_log : journal append-only de TOUTE action admin
--     sensible (qui / quoi / quand / détails). Lecture admin seulement ;
--     ÉCRITURE UNIQUEMENT via public.admin_logger() (security definer) —
--     aucune policy INSERT/UPDATE/DELETE n'est ouverte aux clients, donc
--     le journal ne peut pas être trafiqué ni supprimé depuis le site.
--   · Trois actions admin qui passaient par des écritures directes de
--     table (RLS seule, sans trace) sont converties en RPC qui journalisent :
--       - admin_valider_compte   (remplace l'update direct de profiles)
--       - admin_creer_blocage    (remplace l'insert direct de exclusions)
--       - admin_retirer_blocage  (remplace le delete direct de exclusions)
--   · admin_maj_facture_statut (SQL 10) est redéfinie pour journaliser
--     EN PLUS de la note existante dans candidatures.message.
--
-- Défensif : tant que ce fichier n'est pas exécuté, l'admin console
-- affiche une erreur claire pour les gestes concernés (voir admin.html) —
-- rien ne casse ailleurs.
-- =====================================================================

-- ---------------------------------------------------------------------
-- TABLE : journal d'audit admin (append-only)
-- ---------------------------------------------------------------------
create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references public.profiles(id) on delete set null,
  action text not null,        -- ex. 'compte_valide','compte_revoque','blocage_cree','blocage_retire','facture_statut_maj'
  cible_type text,             -- 'profile' | 'exclusion' | 'facture' | …
  cible_id text,                -- id texte libre (uuid simple ou clé composite)
  details jsonb,                -- contexte libre (raison, avant/après, …)
  created_at timestamptz not null default now()
);
create index if not exists idx_audit_log_created on public.admin_audit_log (created_at desc);
create index if not exists idx_audit_log_cible on public.admin_audit_log (cible_type, cible_id);

alter table public.admin_audit_log enable row level security;

-- Lecture : admin seulement. AUCUNE policy d'écriture pour les clients —
-- seule la fonction admin_logger() (security definer, donc hors RLS)
-- peut insérer. Le journal est donc infalsifiable depuis le site.
drop policy if exists "audit_log_select_admin" on public.admin_audit_log;
create policy "audit_log_select_admin" on public.admin_audit_log
  for select using (public.est_admin());

revoke all on public.admin_audit_log from public, anon, authenticated;
grant select on public.admin_audit_log to authenticated;   -- filtré par la policy ci-dessus

-- ---------------------------------------------------------------------
-- admin_logger — point d'écriture UNIQUE du journal. Toute RPC admin
-- privilégiée l'appelle après son geste. Refuse si l'appelant n'est
-- pas admin (défense en profondeur, même si déjà vérifié par l'appelant).
-- ---------------------------------------------------------------------
create or replace function public.admin_logger(
  p_action text, p_cible_type text, p_cible_id text, p_details jsonb
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  insert into public.admin_audit_log (admin_id, action, cible_type, cible_id, details)
  values (auth.uid(), p_action, p_cible_type, p_cible_id, p_details);
end;
$$;
revoke all on function public.admin_logger(text, text, text, jsonb) from public, anon;
grant execute on function public.admin_logger(text, text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- get_audit_log — lecture pratique pour la console (derniers N, avec
-- le prénom/courriel de l'admin qui a agi).
-- ---------------------------------------------------------------------
create or replace function public.get_audit_log(p_limite int default 200)
returns table (
  id uuid, cree_le timestamptz, admin_id uuid, admin_nom text, admin_courriel text,
  action text, cible_type text, cible_id text, details jsonb
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select l.id, l.created_at, l.admin_id,
           nullif(trim(coalesce(p.prenom,'') || ' ' || coalesce(p.nom,'')), ''),
           p.courriel,
           l.action, l.cible_type, l.cible_id, l.details
      from public.admin_audit_log l
      left join public.profiles p on p.id = l.admin_id
     order by l.created_at desc
     limit greatest(1, least(coalesce(p_limite, 200), 1000));
end;
$$;
revoke all on function public.get_audit_log(int) from public, anon;
grant execute on function public.get_audit_log(int) to authenticated;

-- ---------------------------------------------------------------------
-- admin_valider_compte — remplace l'update direct de profiles.approuve
-- fait jusqu'ici depuis le JS de l'admin console. Journalise qui / quand /
-- raison. La raison est facultative (approbation simple) mais recommandée
-- pour un refus/révocation.
-- ---------------------------------------------------------------------
create or replace function public.admin_valider_compte(
  p_profil uuid, p_valider boolean, p_raison text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_nom text;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;

  update public.profiles
     set approuve = p_valider,
         approuve_date = case when p_valider then now() else null end
   where id = p_profil
  returning coalesce(nom_pharmacie, nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''), courriel)
    into v_nom;

  if not found then raise exception 'Profil introuvable'; end if;

  perform public.admin_logger(
    case when p_valider then 'compte_valide' else 'compte_revoque' end,
    'profile', p_profil::text,
    jsonb_build_object('nom', v_nom, 'raison', p_raison)
  );
end;
$$;
revoke all on function public.admin_valider_compte(uuid, boolean, text) from public, anon;
grant execute on function public.admin_valider_compte(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- admin_creer_blocage / admin_retirer_blocage — remplacent les écritures
-- directes de public.exclusions (insert/delete) faites depuis le JS.
-- Nécessite sql/21-exclusions.sql (table + RLS) déjà en place.
-- ---------------------------------------------------------------------
create or replace function public.admin_creer_blocage(
  p_pharmacien uuid, p_pharmacie uuid, p_raison text default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;

  insert into public.exclusions (pharmacien_id, pharmacie_id, raison, cree_par)
  values (p_pharmacien, p_pharmacie, p_raison, auth.uid())
  on conflict (pharmacien_id, pharmacie_id) do update
    set raison = excluded.raison;

  perform public.admin_logger(
    'blocage_cree', 'exclusion', p_pharmacien::text || ':' || p_pharmacie::text,
    jsonb_build_object('pharmacien_id', p_pharmacien, 'pharmacie_id', p_pharmacie, 'raison', p_raison)
  );
end;
$$;
revoke all on function public.admin_creer_blocage(uuid, uuid, text) from public, anon;
grant execute on function public.admin_creer_blocage(uuid, uuid, text) to authenticated;

create or replace function public.admin_retirer_blocage(
  p_pharmacien uuid, p_pharmacie uuid
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;

  delete from public.exclusions
   where pharmacien_id = p_pharmacien and pharmacie_id = p_pharmacie;
  if not found then raise exception 'Blocage introuvable'; end if;

  perform public.admin_logger(
    'blocage_retire', 'exclusion', p_pharmacien::text || ':' || p_pharmacie::text,
    jsonb_build_object('pharmacien_id', p_pharmacien, 'pharmacie_id', p_pharmacie)
  );
end;
$$;
revoke all on function public.admin_retirer_blocage(uuid, uuid) from public, anon;
grant execute on function public.admin_retirer_blocage(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- admin_maj_facture_statut — redéfinie pour journaliser EN PLUS de la
-- note existante dans candidatures.message (SQL 10). Comportement
-- inchangé sinon (même signature, même validation).
-- ---------------------------------------------------------------------
create or replace function public.admin_maj_facture_statut(
  p_facture uuid, p_statut text, p_note text
)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_cand uuid; v_delai int; v_ref text; v_ancien_statut text;
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  if p_statut not in ('brouillon','envoyee','payee','en_retard') then
    raise exception 'Statut invalide : %', p_statut;
  end if;
  if p_note is null or length(trim(p_note)) < 3 then
    raise exception 'Note d''audit obligatoire (min. 3 caractères)';
  end if;

  select delai_paiement_jours into v_delai from public.regles_reseau where id = 1;
  select statut into v_ancien_statut from public.factures where id = p_facture;

  update public.factures
     set statut = p_statut,
         date_envoi = case
           when p_statut = 'brouillon' then null
           when p_statut in ('envoyee','en_retard','payee') then coalesce(date_envoi, now())
         end,
         date_echeance = case
           when p_statut = 'brouillon' then null
           when p_statut in ('envoyee','en_retard','payee')
             then coalesce(date_echeance, current_date + coalesce(v_delai, 30))
         end,
         date_paiement = case
           when p_statut = 'payee' then coalesce(date_paiement, now())
           else null
         end
   where id = p_facture
   returning candidature_id into v_cand;
  if v_cand is null then raise exception 'Facture introuvable'; end if;

  select k.numero_reference into v_ref
    from public.candidatures c join public.contrats k on k.id = c.contrat_id
   where c.id = v_cand;

  -- piste d'audit existante ('auto' → aucun courriel)
  update public.candidatures
     set message = public.ajouter_jalon(message, jsonb_build_object(
       'etape','facture_admin','par','admin',
       'statut',p_statut,'note',trim(p_note),'auto',true))
   where id = v_cand;

  -- + journal admin centralisé
  perform public.admin_logger(
    'facture_statut_maj', 'facture', p_facture::text,
    jsonb_build_object('ref', v_ref, 'de', v_ancien_statut, 'vers', p_statut, 'note', trim(p_note))
  );
end;
$$;
revoke all on function public.admin_maj_facture_statut(uuid, text, text) from public, anon;
grant execute on function public.admin_maj_facture_statut(uuid, text, text) to authenticated;
