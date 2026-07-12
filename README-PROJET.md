# C-Direct — Plateforme de remplacement en pharmacie (Québec)
**Propriétaire : Robert (Edouard) Malak · État : prêt à déployer · Hébergement : Netlify (gratuit)**

## Ce que c'est
Plateforme statique (10 fichiers, aucun serveur) reliant pharmacies et pharmaciens remplaçants EN DIRECT :
0 % commission (cadre légal : jamais de pourcentage — éviter la classification d'agence de placement CNESST).
Monétisation future permise : abonnement fixe pharmacies et/ou service de facturation à tarif fixe (à faire bénir par Martin Ouellet avant de facturer).

## Carte du site
| Fichier | Rôle | Accès |
|---|---|---|
| index.html | Accueil bilingue FR/EN : présentation, comparaison vs agences, connexion + inscription | Public |
| pharmacies.html | Portail pharmacies : 5 cartes pharmaciens, calendrier Google en temps réel par pharmacien | Code pharmacie |
| espace-pharmacien.html | Portail pharmacien : calendrier, demandes, facturation-conciergerie | Code pharmacien |
| demande.html | Étape 1 — la pharmacie crée la demande (n° contrat auto CD-AAAAMMJJ-###, distance auto) | Pharmacie |
| reponse.html | Étape 2 — le pharmacien accepte ou contre-offre (taux seulement) | Pharmacien |
| contre-offre.html | Étape 3 — la pharmacie accepte la contre-offre | Pharmacie |
| facture.html | MANDAT format Belocum : 4 paramètres, TPS/TVQ, Interac, auto-rempli du contrat | Admin + auto |
| profil.html | Inscription complète (une fois) : pharmacien (incorporé/TPS/TVQ) et pharmacie (lien personnalisé) | Public |
| admin.html | Console admin : approbations, règles du réseau, outils | Code admin |
| fiche.js | FICHIER CENTRAL : données pharmaciens + clé admin + RÈGLES du réseau | — |

## Règles du réseau (fiche.js → REGLES)
- tauxMinimum : 95 $/h — plancher ; pharmacie et pharmacien peuvent offrir PLUS, jamais moins
- tauxKm : 0,70 $/km — fixe ; aller-retour facturé automatiquement (distance calculée domicile↔pharmacie via OpenStreetMap)
- perDiemJour : 125 $ et hebergementNuit : 250 $ — automatiques si > 100 km aller simple ; modifiables par PERSONNE
- Règles ré-appliquées à la lecture de chaque page (anti-contournement par URL)

## Flux complet
Pharmacie (lien personnalisé) → demande.html → courriel au pharmacien → reponse.html (accepter / contre-offre taux) →
[si contre-offre] contre-offre.html → acceptation → facture.html auto-remplie → « Envoyer aux deux parties » →
paiement Interac DIRECT au pharmacien. Admin reçoit copie de chaque étape.

## À compléter avant lancement (chercher ✏️)
1. fiche.js : courriel de Robert, clé Web3Forms de Robert, courriel Interac (+ CLE_ADMIN) — le reste est pré-rempli (Edouard Abdel Malak Pharmacien Inc, TPS 845655646RT0001, TVQ 1219458181TQ0002, domicile Boucherville, 114 $/h)
2. index.html : clé Web3Forms admin (2 formulaires) + 3 codes d'accès
3. admin.html : les 3 mêmes codes (doivent correspondre)
4. profil.html : clé Web3Forms admin
5. pharmacies.html : fiche des 5 pharmaciens (cartes + clés + calendriers) — lancer avec 2 réels, retirer les cartes vides

## Déploiement
Netlify → Deploys → téléverser TOUS les fichiers ensemble (index.html obligatoire pour la racine).
Test complet : inscription fictive → approbation admin → demande → contre-offre → facture → envoi aux deux parties.

## Onboarding d'un nouveau pharmacien (2 min)
profil.html rempli par lui → courriel reçu → admin.html Étape 1 : COLLER le courriel → Analyser →
vérifier OPQ (bouton registre) → Télécharger fiche.js mis à jour → re-téléverser sur Netlify →
Étape 2 : courriel d'approbation prérempli avec code. (Fonctionne aussi avec l'inscription rapide d'index.html —
les champs manquants sont marqués ✏️ dans le bloc généré.)

## Phase 2 (quand traction réelle)
Backend (Supabase) : vrais comptes, contrats stockés, tableau de bord. QuickBooks + Virement Interac par facture.
Monétisation : abonnement pharmacies fixe / service facturation fixe — validation Martin d'abord.

## Site personnel séparé
remplacement-rx.html : site solo de Robert (calendrier + réservation + Payer ma facture Interac) — antérieur à C-Direct, toujours utilisable.
