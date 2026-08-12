-- =====================================================================
-- 75 — T10 (batch1) : déprécier le mécanisme Interac mort de sql/42
-- ---------------------------------------------------------------------
-- Deux mécanismes de vérification du courriel Interac coexistaient :
--   · sql/42 : table verification_interac + RPC demander_/confirmer_
--     verification_courriel_interac (par TOKEN) — jamais branché : aucun
--     appelant dans tout le front (grep *.html/*.js = zéro).
--   · sql/47 : profiles.courriel_interac_* (par CODE) — le mécanisme
--     VIVANT, utilisé par facture-vue.html et get_factures().
-- Une seule source de vérité pour un état anti-fraude : on supprime les
-- deux RPC mortes. La TABLE verification_interac reste (dépréciée) parce
-- que le moteur d'auto-acceptation la lit encore (sql/70, porte j —
-- refroidissement 72 h). À NOTER : cette porte lit une table que plus
-- rien n'écrit — elle devra être repointée vers
-- profiles.courriel_interac_cooldown dans une passe dédiée au moteur,
-- après quoi la table pourra être supprimée.
-- =====================================================================

drop function if exists public.demander_verification_courriel_interac(text);
drop function if exists public.confirmer_verification_courriel_interac(uuid);

comment on table public.verification_interac is
  'DÉPRÉCIÉE (sql/75) — mécanisme token de sql/42 jamais branché ; le vrai état de vérification Interac vit dans profiles.courriel_interac_* (sql/47). Encore lue par la porte j du moteur d''auto-acceptation (sql/70) — repointer cette porte vers profiles.courriel_interac_cooldown avant de supprimer la table.';

-- Vérification :
--   select proname from pg_proc where proname like '%verification_courriel_interac%';  -- doit être vide
