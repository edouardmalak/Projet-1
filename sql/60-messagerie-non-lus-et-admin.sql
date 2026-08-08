/* =====================================================================
   sql/60 — Notification de nouveau message (demande de Robert, 2026-08-08)
   ---------------------------------------------------------------------
   Deux volets, confirmés avec Robert avant de coder :
   (1) Suivi "lu / non lu" — n'existait nulle part avant ce fichier — sur
       les fils pharmacie↔pharmacien existants (sql/18/23/41).
   (2) Nouveau canal SÉPARÉ admin → utilisateur (une pharmacie ou un
       pharmacien), distinct des fils privés pharmacie↔pharmacien — pas
       une réparation de l'accès admin aux fils existants (option écartée
       par Robert : plus intrusif, et admin.html n'a de toute façon jamais
       eu accès réel — messages.html exige ['pharmacien','pharmacie'] et
       mes_fils() filtre sur auth.uid() in (pharmacie_id, pharmacien_id),
       donc l'entrée « Clavardage » du menu admin ne menait nulle part).
   ===================================================================== */

-- ---------- (1) lu/non lu sur les fils existants ----------
alter table public.fils add column if not exists pharmacie_vu_le  timestamptz;
alter table public.fils add column if not exists pharmacien_vu_le timestamptz;

create or replace function public.marquer_fil_vu(p_fil uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  update public.fils set
    pharmacie_vu_le  = case when pharmacie_id  = auth.uid() then now() else pharmacie_vu_le  end,
    pharmacien_vu_le = case when pharmacien_id = auth.uid() then now() else pharmacien_vu_le end
  where id = p_fil and (pharmacie_id = auth.uid() or pharmacien_id = auth.uid());
end;
$$;
revoke all on function public.marquer_fil_vu(uuid) from public, anon;
grant execute on function public.marquer_fil_vu(uuid) to authenticated;

-- mes_fils() : même contenu que sql/41, + non_lu (changement de signature
-- de retour -> drop d'abord, comme sql/41 l'avait fait sur la version sql/23).
drop function if exists public.mes_fils();
create function public.mes_fils()
returns table (
  fil_id uuid, statut text,
  cloture_pharmacie boolean, cloture_pharmacien boolean,
  contrepartie_nom text, contrat_ref text,
  dernier_message text, dernier_le timestamptz, nb_messages bigint,
  contrepartie_note_moyenne numeric, contrepartie_note_nombre bigint,
  contrepartie_favoris_nombre bigint, non_lu boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select f.id, f.statut, f.cloture_pharmacie, f.cloture_pharmacien,
           case when auth.uid() = f.pharmacie_id
                then nullif(trim(coalesce(pn.prenom,'')||' '||coalesce(pn.nom,'')),'')
                else coalesce(nullif(pe.nom_pharmacie,''),
                              nullif(trim(coalesce(pe.prenom,'')||' '||coalesce(pe.nom,'')),''))
           end,
           k.numero_reference,
           (select m.corps from public.messages m
             where m.fil_id = f.id order by m.created_at desc limit 1),
           (select m.created_at from public.messages m
             where m.fil_id = f.id order by m.created_at desc limit 1),
           (select count(*) from public.messages m where m.fil_id = f.id),
           (select np.moyenne from public.get_note_profil(
              case when auth.uid() = f.pharmacie_id then f.pharmacien_id else f.pharmacie_id end) np),
           (select np.nombre from public.get_note_profil(
              case when auth.uid() = f.pharmacie_id then f.pharmacien_id else f.pharmacie_id end) np),
           case when auth.uid() = f.pharmacie_id
             then (select count(*) from public.favoris_pharmaciens fp where fp.pharmacien_id = f.pharmacien_id)
             else null end,
           exists(
             select 1 from public.messages m
              where m.fil_id = f.id
                and m.expediteur_id <> auth.uid()
                and m.created_at > coalesce(
                      case when auth.uid() = f.pharmacie_id then f.pharmacie_vu_le else f.pharmacien_vu_le end,
                      '-infinity'::timestamptz))
      from public.fils f
      join public.profiles pe on pe.id = f.pharmacie_id
      join public.profiles pn on pn.id = f.pharmacien_id
      left join public.contrats k on k.id = f.contrat_id
     where auth.uid() in (f.pharmacie_id, f.pharmacien_id)
     order by f.statut, coalesce(
       (select max(m.created_at) from public.messages m where m.fil_id = f.id),
       f.created_at) desc;
end;
$$;
revoke all on function public.mes_fils() from public, anon;
grant execute on function public.mes_fils() to authenticated;

-- ---------- (2) nouveau canal admin <-> utilisateur ----------
-- Un seul fil par utilisateur (pharmacie ou pharmacien) avec « l'équipe
-- C-Direct » — utilisateur_id identifie le fil, pas besoin d'une table
-- fils_admin séparée. Séparé de public.messages/fils : n'entre PAS dans
-- les conversations privées pharmacie<->pharmacien.
create table if not exists public.messages_admin (
  id uuid primary key default gen_random_uuid(),
  utilisateur_id uuid not null references public.profiles(id) on delete cascade, -- la pharmacie ou le pharmacien concerné (jamais un admin)
  expediteur_id  uuid not null references public.profiles(id) on delete cascade, -- qui a écrit (l'utilisateur OU un admin)
  corps text not null check (char_length(corps) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists messages_admin_utilisateur_idx on public.messages_admin (utilisateur_id, created_at);

alter table public.messages_admin enable row level security;

drop policy if exists messages_admin_lecture on public.messages_admin;
create policy messages_admin_lecture on public.messages_admin for select
  using (utilisateur_id = auth.uid() or public.est_admin());

drop policy if exists messages_admin_ecriture on public.messages_admin;
create policy messages_admin_ecriture on public.messages_admin for insert
  with check (
    expediteur_id = auth.uid()
    and (utilisateur_id = auth.uid() or public.est_admin())
  );

-- Suivi lu/non lu du canal admin — une ligne par utilisateur, jamais
-- écrite directement par le client (seulement via marquer_admin_vu,
-- security definer) : pas de policy insert/update ci-dessous.
create table if not exists public.messages_admin_etat (
  utilisateur_id uuid primary key references public.profiles(id) on delete cascade,
  utilisateur_vu_le timestamptz,
  admin_vu_le timestamptz
);
alter table public.messages_admin_etat enable row level security;
drop policy if exists messages_admin_etat_lecture on public.messages_admin_etat;
create policy messages_admin_etat_lecture on public.messages_admin_etat for select
  using (utilisateur_id = auth.uid() or public.est_admin());

create or replace function public.marquer_admin_vu(p_utilisateur uuid default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_cible uuid;
begin
  if public.est_admin() then
    if p_utilisateur is null then return; end if;
    v_cible := p_utilisateur;
    insert into public.messages_admin_etat (utilisateur_id, admin_vu_le)
    values (v_cible, now())
    on conflict (utilisateur_id) do update set admin_vu_le = now();
  else
    v_cible := auth.uid();
    insert into public.messages_admin_etat (utilisateur_id, utilisateur_vu_le)
    values (v_cible, now())
    on conflict (utilisateur_id) do update set utilisateur_vu_le = now();
  end if;
end;
$$;
revoke all on function public.marquer_admin_vu(uuid) from public, anon;
grant execute on function public.marquer_admin_vu(uuid) to authenticated;

-- Liste des conversations admin (une par utilisateur qui a déjà échangé) —
-- pour admin-messages.html. Démarrer une TOUTE NOUVELLE conversation (avec
-- quelqu'un qui n'a encore aucun message) se fait par simple sélection de
-- profil côté client : admin lit déjà tous les profils (profiles RLS,
-- sql/01, autorise `est_admin()` en lecture), pas besoin d'une RPC de plus.
create or replace function public.admin_lister_conversations()
returns table (
  utilisateur_id uuid, nom text, role text,
  dernier_message text, dernier_le timestamptz, nb_messages bigint, non_lu boolean
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select p.id,
           coalesce(nullif(p.nom_pharmacie,''),
                    nullif(trim(coalesce(p.prenom,'')||' '||coalesce(p.nom,'')),''),
                    p.courriel),
           p.role,
           (select m.corps from public.messages_admin m where m.utilisateur_id = p.id order by m.created_at desc limit 1),
           (select m.created_at from public.messages_admin m where m.utilisateur_id = p.id order by m.created_at desc limit 1),
           (select count(*) from public.messages_admin m where m.utilisateur_id = p.id),
           exists(
             select 1 from public.messages_admin m
             left join public.messages_admin_etat e on e.utilisateur_id = m.utilisateur_id
            where m.utilisateur_id = p.id
              and m.expediteur_id = m.utilisateur_id   -- envoyé par l'utilisateur, pas par un admin
              and m.created_at > coalesce(e.admin_vu_le, '-infinity'::timestamptz))
      from public.profiles p
     where p.role in ('pharmacien','pharmacie')
       and exists (select 1 from public.messages_admin m where m.utilisateur_id = p.id)
     order by (select max(m.created_at) from public.messages_admin m where m.utilisateur_id = p.id) desc;
end;
$$;
revoke all on function public.admin_lister_conversations() from public, anon;
grant execute on function public.admin_lister_conversations() to authenticated;

-- ---------- compteur unique pour le badge de nav (toutes pages, tous rôles) ----------
create or replace function public.compter_messages_non_lus()
returns integer
language plpgsql stable security definer set search_path = public
as $$
declare v_total integer := 0;
begin
  if public.est_admin() then
    select count(*) into v_total
      from public.messages_admin m
      left join public.messages_admin_etat e on e.utilisateur_id = m.utilisateur_id
     where m.expediteur_id = m.utilisateur_id
       and m.created_at > coalesce(e.admin_vu_le, '-infinity'::timestamptz);
    return coalesce(v_total, 0);
  end if;

  select coalesce(sum(x.n), 0) into v_total
    from (
      select count(*) as n
        from public.fils f
        join public.messages m on m.fil_id = f.id
       where f.statut = 'ouvert'
         and (f.pharmacie_id = auth.uid() or f.pharmacien_id = auth.uid())
         and m.expediteur_id <> auth.uid()
         and m.created_at > coalesce(
               case when f.pharmacie_id = auth.uid() then f.pharmacie_vu_le else f.pharmacien_vu_le end,
               '-infinity'::timestamptz)
    ) x;

  v_total := v_total + coalesce((
    select count(*)
      from public.messages_admin m
      left join public.messages_admin_etat e on e.utilisateur_id = auth.uid()
     where m.utilisateur_id = auth.uid()
       and m.expediteur_id <> auth.uid()
       and m.created_at > coalesce(e.utilisateur_vu_le, '-infinity'::timestamptz)
  ), 0);

  return v_total;
end;
$$;
revoke all on function public.compter_messages_non_lus() from public, anon;
grant execute on function public.compter_messages_non_lus() to authenticated;
