-- =====================================================================
-- 83 — TROIS CORRECTIONS AU RAIL DE GARANTIE DE PAIEMENT
-- =====================================================================
-- Trouvées pendant le premier test avec de l'argent réel (2026-08-18,
-- contrat CD-100001, autorisation puis capture à 50 ¢).
--
--  1. L'heure des quarts était interprétée en UTC au lieu de l'heure du
--     Québec — décalage de 4 h (5 h l'hiver) sur toute la mécanique T-24h.
--  2. Le filet « capturer avant expiration » se déclenchait même pour un
--     quart qui n'avait jamais eu lieu.
--  3. Le journal perdait l'affichage de la ligne « captured ».
--
-- Après ce script, `npx wrangler deploy` est REQUIS depuis
-- workers/c-direct-payments (la correction 3 change la forme de retour de
-- lister_garanties_a_capturer, que le Worker consomme).
-- =====================================================================


-- ---------------------------------------------------------------------
-- CORRECTION 1 — l'heure des quarts, en heure du Québec
-- ---------------------------------------------------------------------
-- La base tourne en UTC. `date_contrat` est une date et `heure_debut` une
-- heure nue ; leur somme est un timestamp SANS fuseau. Le `::timestamptz`
-- utilisé jusqu'ici le lisait donc comme de l'UTC : un quart publié pour
-- 8 h du matin à Montréal était vu comme 8 h UTC, soit 4 h du matin heure
-- locale. La fenêtre T-24 h et l'échelle de relance (T-18h / T-12h / T-6h)
-- étaient toutes décalées de 4 heures par rapport au vrai début du quart,
-- et un quart tôt le matin pouvait sortir de la fenêtre sans jamais être
-- autorisé.
--
-- `at time zone 'America/Toronto'` lit le timestamp COMME étant à l'heure
-- du Québec et rend un timestamptz correctement ancré. C'est déjà la
-- convention partout ailleurs dans le dépôt (sql/09, sql/28, sql/68,
-- sql/70) — le bloc « garanties » était le seul à ne pas la suivre.
-- America/Toronto et America/Montreal ont exactement les mêmes décalages
-- et la même heure avancée ; on garde Toronto par cohérence avec l'existant.
--
-- La FORME DE RETOUR NE CHANGE PAS : le Worker n'a rien à adapter ici,
-- `debut_quart` devient simplement juste, ce qui corrige du même coup
-- calculerProchainePhase() côté Worker.

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
           (k.date_contrat::timestamp + coalesce(c.heure_debut_proposee, k.heure_debut))
             at time zone 'America/Toronto',
           k.numero_reference,
           g.id, g.tentative_autorisation, g.palier
      from public.candidatures c
      join public.contrats k on k.id = c.contrat_id
      left join public.garanties_paiement g on g.candidature_id = c.id
     where c.statut = 'accepte'
       and k.statut = 'attribue'
       and (k.date_contrat::timestamp + coalesce(c.heure_debut_proposee, k.heure_debut))
             at time zone 'America/Toronto'
             between now() and now() + make_interval(hours => p_fenetre_heures)
       and (
         g.id is null                                                     -- jamais tenté
         or (
           g.statut = 'authorization_failed'
           and g.tentative_autorisation < 5
           and (g.prochaine_tentative is null or g.prochaine_tentative <= now())
         )
       );
end;
$$;
revoke all on function public.lister_candidatures_a_autoriser(int) from public, anon, authenticated;
grant execute on function public.lister_candidatures_a_autoriser(int) to service_role;


-- ---------------------------------------------------------------------
-- CORRECTIONS 2 ET 3 — le filet de capture, et le statut au journal
-- ---------------------------------------------------------------------
-- CORRECTION 2. Deux déclencheurs mènent à une capture :
--   a) l'échéance de confirmation est passée — le pharmacien avait reçu sa
--      facture, le délai est écoulé, on capture. INCHANGÉ.
--   b) l'autorisation est sur le point d'expirer — filet volontaire pour
--      ne jamais laisser un pharmacien impayé parce que la carte a lâché.
--
-- Le (b) se déclenchait sans AUCUNE condition sur le quart lui-même. Une
-- garantie posée sur un quart qui n'a jamais eu lieu — annulé, ou dont la
-- feuille de temps n'a jamais été soumise, donc sans facture ni échéance —
-- finissait quand même par débiter la carte de la pharmacie ~7 jours plus
-- tard, pour un travail qui n'a pas été fait. C'est exactement ce qui
-- serait arrivé à l'autorisation de test du 2026-08-18 si on l'avait
-- laissée dormir.
--
-- On garde le filet, mais on exige désormais que le quart soit RÉELLEMENT
-- TERMINÉ (heure de fin passée, gestion du quart de nuit incluse) et que
-- le contrat ne soit pas annulé. Un quart livré dont la pharmacie ne donne
-- plus signe de vie est toujours protégé ; un quart qui n'a pas eu lieu ne
-- coûte plus rien à personne — l'autorisation expire d'elle-même, sans
-- frais, ce qui est le comportement correct.
--
-- CORRECTION 3. La fonction renvoie maintenant aussi `statut`. Le Worker
-- journalisait la capture avec `ancien_statut = null`, ce qui faisait
-- disparaître la ligne de tout relevé construit par concaténation
-- (`ancien_statut || '->' || nouveau_statut` vaut NULL dès qu'un membre est
-- NULL). La ligne existait, mais restait invisible — précisément dans la
-- table qui sert de preuve en cas de contestation de carte.
--
-- ⚠️ LA FORME DE RETOUR CHANGE (colonne `statut` ajoutée) : le Worker doit
-- être redéployé en même temps que ce script.

drop function if exists public.lister_garanties_a_capturer();
create or replace function public.lister_garanties_a_capturer()
returns table (
  garantie_id uuid, stripe_payment_intent_id text, pharmacien_id uuid, statut text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select g.id, g.stripe_payment_intent_id, c.pharmacien_id, g.statut
      from public.garanties_paiement g
      join public.candidatures c on c.id = g.candidature_id
      join public.contrats k on k.id = c.contrat_id
     where g.statut in ('authorized', 'pending_locum_confirmation', 'amount_mismatch')
       and k.statut <> 'annule'
       and (
         -- (a) délai de confirmation dépassé — inchangé
         (g.echeance_confirmation is not null and g.echeance_confirmation <= now())
         -- (b) filet d'expiration, désormais réservé aux quarts terminés
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
       );
end;
$$;
revoke all on function public.lister_garanties_a_capturer() from public, anon, authenticated;
grant execute on function public.lister_garanties_a_capturer() to service_role;


-- ---------------------------------------------------------------------
-- VÉRIFICATION — avant/après sur un quart de 8 h du matin aujourd'hui
-- ---------------------------------------------------------------------
select 'Un quart a 08:00 aujourd hui etait lu comme' as explication,
       (current_date + '08:00'::time)::timestamptz                         as ancien_utc,
       (current_date::timestamp + '08:00'::time)
         at time zone 'America/Toronto'                                    as nouveau_quebec,
       (current_date::timestamp + '08:00'::time) at time zone 'America/Toronto'
         - (current_date + '08:00'::time)::timestamptz                     as ecart_corrige;
