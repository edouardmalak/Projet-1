-- =====================================================================
-- C-DIRECT · PAIEMENTS STRIPE · SQL 46 — ÉCHELLE DE RELANCE (tâche #21)
-- À exécuter APRÈS sql/45-retry-autorisations-echouees.sql, dans
-- Supabase → SQL Editor.
--
-- Avant ce fichier, un échec d'autorisation était retenté au cycle
-- SUIVANT (15 min plus tard), jusqu'à 5 fois — ce qui épuise les 5
-- essais en ~1h15 au lieu de suivre l'échelle prévue par le skill
-- c-direct-payments (T-24h → retry T-18h → SMS T-12h → escalade T-6h).
-- Ce fichier ajoute un VRAI espacement dans le temps, calé sur l'heure
-- du quart plutôt que sur un compteur de cycles.
--
-- Palier « carte de secours » PAS construit : aucune notion de
-- deuxième carte n'existe encore dans stripe_comptes (une seule
-- stripe_payment_method_id par pharmacie). Noté, pas caché — voir
-- commentaire dans workers/c-direct-payments/src/index.js.
-- =====================================================================

alter table public.garanties_paiement
  add column if not exists palier text,
  add column if not exists prochaine_tentative timestamptz;

comment on column public.garanties_paiement.palier is
  'Étape de l''échelle de relance atteinte : null (jamais échoué ou T-24h),
   T-18h, T-12h-sms, T-6h-escalade. Sert à n''envoyer le SMS qu''UNE fois
   par palier (pas à chaque cycle de 15 min pendant qu''on y est).';
comment on column public.garanties_paiement.prochaine_tentative is
  'Prochain instant où le Worker a le droit de retenter cette garantie.
   NULL = éligible immédiatement (jamais échoué). Empêche le marteau-
   piqueur de 15 min et fait respecter l''échelle T-18h/T-12h/T-6h.';

create index if not exists idx_garanties_paiement_prochaine_tentative
  on public.garanties_paiement (prochaine_tentative)
  where statut = 'authorization_failed';

-- ---------------------------------------------------------------------
-- lister_candidatures_a_autoriser — RECRÉÉE (forme de retour changée) :
-- ajoute palier_precedent (pour que le Worker sache s'il vient de
-- CHANGER de palier, seul moment où le SMS doit partir) + numero_reference
-- (pour le corps du SMS, évite un aller-retour Supabase de plus) + gate
-- sur prochaine_tentative en plus du compteur de tentatives.
-- ---------------------------------------------------------------------
drop function if exists public.lister_candidatures_a_autoriser(int);
create or replace function public.lister_candidatures_a_autoriser(p_fenetre_heures int default 24)
returns table (
  candidature_id uuid, pharmacien_id uuid, pharmacie_id uuid,
  montant_locum numeric, debut_quart timestamptz, numero_reference text,
  garantie_id uuid, tentative_precedente int, palier_precedent text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select c.id, c.pharmacien_id, k.pharmacie_id,
           public.calculer_montant_locum(c.id),
           (k.date_contrat + coalesce(c.heure_debut_proposee, k.heure_debut))::timestamptz,
           k.numero_reference,
           g.id, g.tentative_autorisation, g.palier
      from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      left join public.garanties_paiement g on g.candidature_id = c.id
     where c.statut = 'accepte'
       and k.statut = 'attribue'
       and (k.date_contrat + coalesce(c.heure_debut_proposee, k.heure_debut))::timestamptz
             between now() and now() + make_interval(hours => p_fenetre_heures)
       and (
         g.id is null                                                     -- jamais tenté
         or (
           g.statut = 'authorization_failed'
           and g.tentative_autorisation < 5
           and (g.prochaine_tentative is null or g.prochaine_tentative <= now())  -- respecte l'échelle
         )
       );
end;
$$;
revoke all on function public.lister_candidatures_a_autoriser(int) from public, anon, authenticated;
grant execute on function public.lister_candidatures_a_autoriser(int) to service_role;

-- ---------------------------------------------------------------------
-- RPC admin · admin_lister_garanties_en_difficulte — garanties encore en
-- 'authorization_failed', pour un panneau visible dans admin.html (le
-- palier T-6h-escalade est censé être vu par un humain, pas seulement
-- retenté en boucle jusqu'à épuisement des 5 essais).
-- ---------------------------------------------------------------------
create or replace function public.admin_lister_garanties_en_difficulte()
returns table (
  garantie_id uuid, candidature_id uuid, numero_reference text, date_contrat date,
  pharmacie_nom text, pharmacien_nom text, palier text, tentative_autorisation int,
  derniere_erreur text, prochaine_tentative timestamptz, montant_locum numeric
)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.est_admin() then raise exception 'Accès refusé'; end if;
  return query
    select g.id, c.id, k.numero_reference, k.date_contrat,
           pe.nom_pharmacie,
           trim(coalesce(pn.prenom,'') || ' ' || coalesce(pn.nom,'')),
           g.palier, g.tentative_autorisation, g.derniere_erreur, g.prochaine_tentative,
           round(g.montant_locum_cents / 100.0, 2)
      from public.garanties_paiement g
      join public.candidatures c on c.id = g.candidature_id
      join public.contrats k on k.id = c.contrat_id
      join public.profiles pe on pe.id = k.pharmacie_id
      join public.profiles pn on pn.id = c.pharmacien_id
     where g.statut = 'authorization_failed'
     order by k.date_contrat asc;
end;
$$;
revoke all on function public.admin_lister_garanties_en_difficulte() from public, anon;
grant execute on function public.admin_lister_garanties_en_difficulte() to authenticated;

-- Vérification : select * from public.admin_lister_garanties_en_difficulte();
