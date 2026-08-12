-- =====================================================================
-- 76 — T17 (batch1) : interrupteur admin « Dispensaire » visible / masqué
-- ---------------------------------------------------------------------
-- Colonne unique dans regles_reseau (rangée 1, déjà lisible par tous les
-- connectés et modifiable par l'admin seulement — RLS de sql/03) :
--   true  (défaut) → « Formations » (pharmacien) et « Dispensaire »
--                     (pharmacie) apparaissent dans le menu de compte.
--   false          → auth.js retire ces entrées des DEUX menus.
-- L'accès admin (admin-articles.html) n'est pas touché.
-- =====================================================================

alter table public.regles_reseau
  add column if not exists dispensaire_visible boolean not null default true;

-- Vérification : select dispensaire_visible from public.regles_reseau where id = 1;
