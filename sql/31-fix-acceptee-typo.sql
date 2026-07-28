-- =========================================================================
-- 31 — correctif : 'acceptee' (invalide) → 'accepte' (valeur réelle)
-- ---------------------------------------------------------------------
-- Le check constraint sur candidatures.statut n'autorise que
-- ('propose','contre_offre','accepte','refuse') — voir sql/02. Trois
-- endroits de sql/23-phase8.sql cherchaient 'acceptee' (avec un e de
-- trop), une valeur qui n'existe jamais en base. Conséquence concrète :
--   • get_fiche_accueil refusait TOUJOURS l'accès au pharmacien assigné
--     (« Accès refusé » sur la fiche « Ce que vous devez savoir »,
--     sauf pour l'admin ou la pharmacie propriétaire).
--   • ouvrir_fil ne retrouvait pas le pharmacien via la candidature
--     quand c'est la PHARMACIE qui initie la conversation.
--   • la migration ponctuelle de sql/23 (rattachement fil_id des
--     anciens messages) n'a rattaché aucun message, faute de jointure.
-- Ce correctif recrée les deux fonctions avec la bonne valeur et
-- termine le rattachement des messages orphelins.
-- =========================================================================

create or replace function public.get_fiche_accueil(p_contrat uuid)
returns table (
  numero_reference text, date_contrat date,
  heure_debut time, heure_fin time,
  nom_pharmacie text, adresse text, ville text, code_postal text,
  logiciel text, telephone text,
  info_contact_nom text, info_contact_tel text,
  info_arrivee text, info_stationnement text, info_instructions text,
  info_plateaux jsonb,
  notes_acces text, rx_jour_semaine int, rx_jour_weekend int
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (
    select 1
      from public.contrats k
      left join public.candidatures c
             on c.contrat_id = k.id
            and c.statut = 'accepte'
     where k.id = p_contrat
       and ( public.est_admin()
             or k.pharmacie_id = auth.uid()
             or c.pharmacien_id = auth.uid() )
  ) then
    raise exception 'Accès refusé';
  end if;

  return query
    select k.numero_reference, k.date_contrat, k.heure_debut, k.heure_fin,
           p.nom_pharmacie, p.adresse, p.ville, p.code_postal,
           p.logiciel, p.telephone,
           p.info_contact_nom, p.info_contact_tel,
           p.info_arrivee, p.info_stationnement, p.info_instructions,
           coalesce(p.info_plateaux, '[]'::jsonb),
           p.notes_acces, p.rx_jour_semaine, p.rx_jour_weekend
      from public.contrats k
      join public.profiles p on p.id = k.pharmacie_id
     where k.id = p_contrat;
end;
$$;
revoke all on function public.get_fiche_accueil(uuid) from public, anon;
grant execute on function public.get_fiche_accueil(uuid) to authenticated;

create or replace function public.ouvrir_fil(p_contrat uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_pharmacie uuid; v_pharmacien uuid; v_fil uuid;
begin
  select k.pharmacie_id,
         coalesce(
           (select c.pharmacien_id from public.candidatures c
             where c.contrat_id = k.id and c.statut = 'accepte' limit 1),
           case when public.mon_role() = 'pharmacien' then auth.uid() else null end)
    into v_pharmacie, v_pharmacien
    from public.contrats k
   where k.id = p_contrat;

  if v_pharmacie is null or v_pharmacien is null then
    raise exception 'Contrat introuvable ou aucun pharmacien rattaché';
  end if;

  if not (public.est_admin() or auth.uid() in (v_pharmacie, v_pharmacien)) then
    raise exception 'Accès refusé';
  end if;

  -- blocage (SQL 21) : pas de fil avec une contrepartie exclue
  if public.est_exclu(v_pharmacien, v_pharmacie) then
    raise exception 'Conversation impossible : cette contrepartie n''est pas accessible.';
  end if;

  select id into v_fil from public.fils
   where pharmacie_id = v_pharmacie and pharmacien_id = v_pharmacien
     and statut = 'ouvert' limit 1;

  if v_fil is null then
    insert into public.fils (pharmacie_id, pharmacien_id, contrat_id)
    values (v_pharmacie, v_pharmacien, p_contrat)
    returning id into v_fil;
  end if;

  return v_fil;
end;
$$;
revoke all on function public.ouvrir_fil(uuid) from public, anon;
grant execute on function public.ouvrir_fil(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Rattrapage : rattacher fil_id aux anciens messages que la migration
-- de sql/23 n'a pas pu traiter à cause du typo (idempotent — ne touche
-- que les messages encore sans fil_id).
-- ---------------------------------------------------------------------
do $$
declare r record; v_fil uuid;
begin
  for r in
    select distinct k.pharmacie_id, c.pharmacien_id, m.contrat_id
      from public.messages m
      join public.contrats k on k.id = m.contrat_id
      join public.candidatures c on c.contrat_id = k.id and c.statut = 'accepte'
     where m.fil_id is null
  loop
    select id into v_fil from public.fils
     where pharmacie_id = r.pharmacie_id and pharmacien_id = r.pharmacien_id
       and statut = 'ouvert' limit 1;
    if v_fil is null then
      insert into public.fils (pharmacie_id, pharmacien_id, contrat_id)
      values (r.pharmacie_id, r.pharmacien_id, r.contrat_id)
      returning id into v_fil;
    end if;
    update public.messages set fil_id = v_fil
     where contrat_id = r.contrat_id and fil_id is null;
  end loop;
end $$;
