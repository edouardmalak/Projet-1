-- =====================================================================
-- 87 — VERROU SUR LE CYCLE DE CAPTURE
-- =====================================================================
-- Le skill exige « SELECT ... FOR UPDATE SKIP LOCKED so overlapping
-- scheduler runs never touch the same row ». Ça n'existait nulle part.
--
-- En cherchant où le trou se trouvait réellement (2026-08-18) :
--
--   AUTORISATION — déjà protégée, par deux mécanismes qui se doublent :
--     `candidature_id` est UNIQUE, donc deux cycles simultanés obtiennent
--     la MÊME ligne de garantie par l'upsert, donc la MÊME clé
--     d'idempotence `<garantie.id>:autoriser`, et Stripe dédoublonne.
--
--   CAPTURE — PAS protégée du tout. L'appel Stripe de capture ne portait
--     AUCUNE clé d'idempotence. Deux cycles qui se chevauchent capturaient
--     une fois, puis le second recevait « already captured », le prenait
--     pour un échec, passait la garantie en capture_failed et envoyait une
--     alerte SMS à la pharmacie plus un courriel admin — pour un paiement
--     qui avait parfaitement réussi.
--
-- Correction en deux couches, comme le veut le skill :
--   1. BASE — une réservation : le cycle marque les lignes qu'il prend
--      (`verrou_jusqu`), et ne renvoie que celles qu'il a réussi à prendre.
--      `for update ... skip locked` garantit que deux cycles simultanés
--      se partagent les lignes au lieu de se les disputer.
--   2. STRIPE — clé d'idempotence sur la capture (dans le Worker).
--
-- Le verrou expire seul après 5 minutes : un Worker qui plante en cours
-- de route ne bloque pas la garantie pour toujours.
--
-- ⚠️ `npx wrangler deploy` REQUIS après ce script.
-- IDEMPOTENT.
-- =====================================================================

alter table public.garanties_paiement
  add column if not exists verrou_jusqu timestamptz;

comment on column public.garanties_paiement.verrou_jusqu is
  'Reservation posee par un cycle de garanties. Tant qu''elle court, aucun autre cycle ne reprend la ligne. Expire seule apres 5 minutes pour ne jamais bloquer definitivement.';

drop function if exists public.lister_garanties_a_capturer();
create or replace function public.lister_garanties_a_capturer()
returns table (garantie_id uuid, stripe_payment_intent_id text, pharmacien_id uuid, statut text)
language plpgsql volatile security definer set search_path = public
as $$
begin
  return query
  with candidats as (
    select g.id
      from public.garanties_paiement g
      join public.candidatures c on c.id = g.candidature_id
      join public.contrats    k on k.id = c.contrat_id
     where g.statut in ('authorized', 'pending_locum_confirmation', 'amount_mismatch')
       and k.statut <> 'annule'
       -- pas deja reservee par un autre cycle
       and (g.verrou_jusqu is null or g.verrou_jusqu < now())
       and (
         -- (a) delai de confirmation depasse
         (g.echeance_confirmation is not null and g.echeance_confirmation <= now())
         -- (b) filet d'expiration, reserve aux quarts REELLEMENT termines (sql/83)
         or (
           g.capture_before is not null
           and g.capture_before <= now() + interval '6 hours'
           and ((k.date_contrat
                  + case when coalesce(c.heure_fin_proposee, k.heure_fin)
                            <= coalesce(c.heure_debut_proposee, k.heure_debut)
                         then 1 else 0 end)::timestamp
                + coalesce(c.heure_fin_proposee, k.heure_fin))
                at time zone 'America/Toronto' <= now()
         )
       )
       for update of g skip locked
  ),
  reserves as (
    update public.garanties_paiement g
       set verrou_jusqu = now() + interval '5 minutes'
      from candidats
     where g.id = candidats.id
    returning g.id, g.stripe_payment_intent_id, g.candidature_id, g.statut
  )
  select r.id, r.stripe_payment_intent_id, c.pharmacien_id, r.statut
    from reserves r
    join public.candidatures c on c.id = r.candidature_id;
end;
$$;
revoke all on function public.lister_garanties_a_capturer() from public, anon, authenticated;
grant execute on function public.lister_garanties_a_capturer() to service_role;

-- ---------------------------------------------------------------------
-- VÉRIFICATION — deux appels successifs : le second doit renvoyer 0 ligne
-- pour tout ce que le premier a déjà réservé.
-- ---------------------------------------------------------------------
select 'appel 1 : ' || (select count(*) from public.lister_garanties_a_capturer())::text
    || ' ligne(s) reservee(s) | appel 2 (doit etre 0) : '
    || (select count(*) from public.lister_garanties_a_capturer())::text as verification_verrou;
