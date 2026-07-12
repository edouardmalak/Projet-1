// =====================================================
// ✏️ FICHE CENTRALE DES PHARMACIENS — C-Direct
// UN SEUL fichier à modifier pour activer un pharmacien.
// (Utilisé par : demande.html, reponse.html,
//  contre-offre.html et facture.html)
// Quand un pharmacien remplit profil.html, vous recevez
// par courriel son bloc prêt à coller ci-dessous.
// =====================================================
const PHARMACIENS = [
  {
    nom: "Edouard Malak",
    courriel: "edouardmalak@gmail.com",
    cle: "6d62e4bb-5cdd-42e9-8c64-5e9a9cf465eb",
    domicile: "1241 Rue de Lisieux, Boucherville, QC J4B 8E8",
    corp: "Edouard Abdel Malak Pharmacien Inc",
    tps: "845655646RT0001",
    tvq: "1219458181TQ0002",
    interac: "edouardmalak@gmail.com",
    tauxH: 114, perDiem: 125, tauxKm: 0.70
  }
  // ← coller les nouveaux pharmaciens ici (bloc reçu par courriel via profil.html)
];


// =====================================================
// ✏️ RÈGLES DU RÉSEAU — fixées par l'administrateur
// Ces règles s'appliquent à TOUS les contrats :
// · tauxMinimum : plancher du taux horaire. La pharmacie
//   peut offrir PLUS, jamais moins. Idem pour le pharmacien.
// · tauxKm : fixe (personne ne peut le changer)
// · perDiemJour + hebergementNuit : montants fixes,
//   appliqués AUTOMATIQUEMENT si la distance aller simple
//   domicile ↔ pharmacie dépasse le seuil. Personne ne
//   peut les modifier ni les retirer.
// =====================================================
const REGLES = {
  tauxMinimum: 95,          // $/h — plancher réseau
  tauxKm: 0.70,             // $/km — fixe
  perDiemJour: 125,         // $/jour — fixe, automatique
  hebergementNuit: 250,     // $/nuit — fixe, automatique
  seuilKmAllerSimple: 100   // km aller simple déclenchant per diem + hébergement
};

// ✏️ Votre clé Web3Forms d'administrateur (copies de toutes les étapes)
const CLE_ADMIN = "6d62e4bb-5cdd-42e9-8c64-5e9a9cf465eb";
