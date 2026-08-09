-- =====================================================================
-- C-DIRECT · SQL 66 — Corrige ouvrir_fil : statut 'acceptee' → 'accepte'
--
-- RÉGRESSION (trouvée 2026-08-09) : sql/31 avait corrigé partout la faute
-- 'acceptee' (double e) → 'accepte'. sql/61 a recréé ouvrir_fil() en
-- réintroduisant 'acceptee' dans le sous-select qui retrouve le pharmacien
-- retenu. Comme aucune candidature n'a jamais le statut 'acceptee'
-- (accepter_candidature pose 'accepte'), le sous-select ne retrouve rien ;
-- pour une PHARMACIE, le repli vaut NULL → « Contrat introuvable ou aucun
-- pharmacien rattaché ». Résultat : une pharmacie ne peut pas ouvrir la
-- conversation d'un contrat confirmé. (Le pharmacien, lui, passe par le
-- repli auth.uid(), d'où le bug longtemps invisible.)
--
-- Corps identique à sql/61, à la seule correction 'acceptee' → 'accepte'.
-- À exécuter dans Supabase → SQL Editor. Idempotent.
-- =====================================================================

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

  if public.est_bloque(v_pharmacien, v_pharmacie) then
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
-- Vérification : doit contenir 'accepte' et non 'acceptee'.
--   select pg_get_functiondef('public.ouvrir_fil(uuid)'::regprocedure);
-- ---------------------------------------------------------------------
