// =====================================================
// C-Direct — VESTIGE de la version pré-base de données
// -----------------------------------------------------
// ⚠️ CE FICHIER EST SERVI PUBLIQUEMENT : https://…/fiche.js
//    répond 200 à n'importe qui, sans authentification.
//    N'Y METTEZ JAMAIS de donnée personnelle ou secrète :
//    pas d'adresse, pas de numéro TPS/TVQ, pas de courriel
//    Interac, pas de clé d'API.
//
// Il contenait auparavant la fiche complète d'un pharmacien
// (domicile, TPS, TVQ, raison sociale, Interac) ainsi qu'une
// clé Web3Forms. Ces données ont été retirées et vivent
// désormais dans le PROFIL privé du pharmacien, en base :
//   · colonnes profiles.tps / tvq / societe  (sql/32)
//   · saisies par le pharmacien dans profil.html
//   · lues par facture-vue.html via get_factures()
//
// Ce qui reste ci-dessous n'est utilisé que par les pages
// héritées, non branchées à la base et non reliées au menu :
//   demande.html · reponse.html · contre-offre.html · facture.html
// Le vrai parcours vit dans espace-pharmacie.html (publication)
// et contrats.html / contrat.html (candidature).
// =====================================================

// Vide : la liste des pharmaciens vient de la base (table profiles),
// jamais d'un fichier public.
const PHARMACIENS = [];

// =====================================================
// Règles du réseau — copie héritée, utilisée uniquement par
// les pages listées plus haut. Les règles qui font foi sont
// celles appliquées en base et affichées par le site.
// =====================================================
const REGLES = {
  tauxMinimum: 95,          // $/h — plancher réseau
  tauxKm: 0.70,             // $/km — fixe
  perDiemJour: 125,         // $/jour — fixe, automatique
  hebergementNuit: 250,     // $/nuit — fixe, automatique
  seuilKmAllerSimple: 100   // km aller simple déclenchant per diem + hébergement
};

// Clé Web3Forms retirée (elle était lisible publiquement).
// Les pages héritées qui la lisaient n'envoient donc plus rien.
const CLE_ADMIN = "";
