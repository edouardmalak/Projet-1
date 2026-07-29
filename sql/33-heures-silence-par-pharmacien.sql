-- =====================================================================
-- C-DIRECT · SQL 33 — Heures de silence : réglage PAR PHARMACIEN
-- ---------------------------------------------------------------------
-- Jusqu'ici la règle était globale et codée dans le Worker : tout SMS
-- destiné à un pharmacien entre 21:00 et 07:00 (America/Montreal) était
-- mis en file et envoyé à 07:00. Personne ne pouvait y déroger, et rien
-- ne l'indiquait à l'écran — un contrat publié à 23:00 semblait donc
-- « ne rien envoyer », alors que le SMS était simplement différé.
--
-- Ce fichier rend la règle optionnelle, pharmacien par pharmacien :
--
--   sms_silence = true   → respecte les heures de silence 21:00–07:00
--                          (COMPORTEMENT ACTUEL — valeur par défaut,
--                           donc rien ne change pour les comptes existants)
--   sms_silence = false  → accepte les SMS à toute heure, envoi immédiat
--
-- Le choix se fait dans la page Profil. Le Worker lit la colonne et
-- calcule l'heure d'envoi destinataire par destinataire.
--
-- Idempotent et sans danger : rejouable, ne détruit aucune donnée, et
-- la valeur par défaut préserve exactement le fonctionnement d'aujourd'hui.
-- =====================================================================

alter table public.profiles
  add column if not exists sms_silence boolean not null default true;

comment on column public.profiles.sms_silence is
  'true = respecter les heures de silence 21:00-07:00 pour les SMS (défaut). '
  'false = le compte accepte les SMS a toute heure.';

-- ---------------------------------------------------------------------
-- Le réglage est offert aux DEUX rôles, mais leur comportement d'origine
-- diffère, et on ne veut rien changer à l'existant :
--
--   · PHARMACIEN — recevait déjà ses SMS de contrat seulement hors
--     21:00–07:00. Le défaut `true` reproduit donc exactement l'ancien
--     comportement : rien à faire.
--
--   · PHARMACIE — recevait TOUJOURS sa confirmation de publication
--     immédiatement, y compris la nuit. Le défaut `true` aurait donc
--     introduit un report à 07:00 que personne n'a demandé. On remet les
--     comptes pharmacie à `false` : confirmation immédiate, comme avant.
--     Une pharmacie qui veut le silence coche la case dans Profil.
-- ---------------------------------------------------------------------
update public.profiles set sms_silence = false where role = 'pharmacie';
