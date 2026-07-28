-- =====================================================================
-- C-DIRECT · SQL 32 — La facturation lit le PROFIL, plus le fichier public
-- ---------------------------------------------------------------------
-- CONTEXTE / POURQUOI
-- `fiche.js` est servi publiquement (https://…/fiche.js renvoie 200 à
-- n'importe qui). Il contenait l'adresse du domicile, les numéros TPS/TVQ,
-- la raison sociale et le courriel Interac du pharmacien — en clair.
-- `facture-vue.html` était la seule page VIVANTE à s'en servir, pour
-- afficher société/TPS/TVQ sur le mandat et décider d'appliquer les taxes.
--
-- Ce fichier déplace ces données du fichier public vers le profil privé :
--   1) ajoute les colonnes tps / tvq / societe (contenu de sql/17, jamais
--      exécuté — la page Profil écrit déjà dans ces champs, il ne manquait
--      que les colonnes) ;
--   2) get_factures renvoie désormais ces 3 champs, protégés par les mêmes
--      règles d'accès qu'avant (admin, pharmacien concerné, pharmacie
--      concernée) ;
--   3) reprend les valeurs qui étaient dans fiche.js pour ne rien perdre.
--
-- Idempotent et sans danger : rejouable, ne détruit aucune donnée.
-- =====================================================================

-- 1) Colonnes de facturation du pharmacien (= sql/17)
alter table public.profiles add column if not exists tps text;
alter table public.profiles add column if not exists tvq text;
alter table public.profiles add column if not exists societe text;

-- 2) get_factures + société/TPS/TVQ du pharmacien
--    (le type de retour change → il faut DROP puis CREATE)
drop function if exists public.get_factures();

create function public.get_factures()
returns table (
  facture_id uuid, numero_facture int, type_facture text, statut text,
  heures numeric, tarif_horaire numeric, km numeric, taux_km numeric,
  per_diem_montant numeric, hebergement_montant numeric, total numeric,
  date_envoi timestamptz, date_paiement timestamptz, date_echeance date,
  cree_le timestamptz,
  candidature_id uuid, contrat_id uuid, numero_reference text, date_contrat date,
  heure_debut time, heure_fin time,
  pharmacien_id uuid, pharmacien_prenom text, pharmacien_nom text,
  pharmacien_opq text, pharmacien_courriel text,
  pharmacie_id uuid, nom_pharmacie text, pharmacie_adresse text,
  pharmacie_ville text, pharmacie_cp text, pharmacie_neq text, pharmacie_courriel text,
  pharmacien_societe text, pharmacien_tps text, pharmacien_tvq text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
    select f.id, f.numero_facture, f.type_facture, f.statut,
           f.heures, f.tarif_horaire, f.km, f.taux_km,
           f.per_diem_montant, f.hebergement_montant, f.total,
           f.date_envoi, f.date_paiement, f.date_echeance,
           f.created_at,
           c.id, k.id, k.numero_reference, k.date_contrat,
           coalesce(c.heure_debut_proposee, k.heure_debut),
           coalesce(c.heure_fin_proposee,  k.heure_fin),
           pn.id, pn.prenom, pn.nom, pn.numero_opq, pn.courriel,
           pe.id, pe.nom_pharmacie, pe.adresse, pe.ville, pe.code_postal, pe.neq, pe.courriel,
           pn.societe, pn.tps, pn.tvq
      from public.factures f
      join public.candidatures c on c.id = f.candidature_id
      join public.contrats k     on k.id = c.contrat_id
      join public.profiles pn    on pn.id = c.pharmacien_id
      join public.profiles pe    on pe.id = k.pharmacie_id
     where public.est_admin()
        or c.pharmacien_id = auth.uid()
        or k.pharmacie_id = auth.uid()
     order by f.created_at desc;
end;
$$;
revoke all on function public.get_factures() from public, anon;
grant execute on function public.get_factures() to authenticated;

-- 3) Reprise des valeurs qui vivaient dans fiche.js (aucun écrasement :
--    on ne remplit que si le champ est encore vide).
--    NOTE (constaté à l'exécution) : 0 ligne touchée. Le compte
--    edouardmalak@gmail.com a le rôle « admin », et les seuls profils
--    « pharmacien » sont des comptes de test (+pharmacien, +pharmacien4).
--    Autrement dit fiche.js ne correspondait à AUCUNE facture réelle :
--    société/TPS/TVQ s'affichaient déjà « — » partout et aucune taxe
--    n'était appliquée. Le retrait de fiche.js ne change donc rien.
--    Les vrais numéros se saisissent maintenant dans la page Profil.
update public.profiles
   set societe = coalesce(nullif(trim(societe), ''), 'Edouard Abdel Malak Pharmacien Inc'),
       tps     = coalesce(nullif(trim(tps),     ''), '845655646RT0001'),
       tvq     = coalesce(nullif(trim(tvq),     ''), '1219458181TQ0002')
 where role = 'pharmacien'
   and lower(courriel) = 'edouardmalak@gmail.com';
