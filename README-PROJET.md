# C-Direct — Plateforme de remplacement en pharmacie (Québec)

**Propriétaire : Robert (Edouard) Malak**
**Hébergement : Cloudflare Pages — https://projet-1-1yi.pages.dev (déploiement automatique à chaque push sur `main`)**
**Base de données : Supabase · Notifications : Workers Cloudflare (`c-direct-sms`, `c-direct-chat`)**

> ⚠️ **Ce dossier est servi publiquement.** Tout fichier à la racine du dépôt
> (y compris les `.md`, `sql/*.sql` et `workers/**`) est téléchargeable par
> n'importe qui à `https://…/<chemin>`. N'y écrivez jamais de numéro de taxes,
> d'adresse personnelle, de clé d'API ni de secret. Les vraies données
> personnelles vivent dans la table privée `profiles` (Supabase), et les
> secrets dans les variables chiffrées des Workers.

## Ce que c'est

Marché à deux côtés reliant pharmacies et pharmaciens remplaçants **en direct**,
à **0 % de commission** (cadre légal : jamais de pourcentage, afin d'éviter la
classification d'agence de placement). Monétisation envisagée : abonnement fixe
ou service de facturation à tarif fixe — à faire valider juridiquement avant
toute facturation.

## Architecture réelle (depuis la Phase 2)

Le site n'est plus statique : chaque page authentifiée parle à Supabase.

- `supabase-config.js` — création du client Supabase (clé anon, publique par design)
- `auth.js` — session, rôles, garde d'accès (`cdExigerConnexion`), menu par rôle, en-tête connecté
- Sécurité — **RLS** sur toutes les tables + fonctions `security definer` ; le
  navigateur ne voit que ce que la base autorise

### Carte du site

| Fichier | Rôle | Accès |
|---|---|---|
| `index.html` | Accueil bilingue FR/EN, présentation, connexion / inscription | Public |
| `acces.html` | Connexion / inscription (courriel, Google) | Public |
| `espace-pharmacie.html` | **Publication d'un contrat** (`#nouvelle-demande`), candidatures reçues, acceptation, KPI, factures | Pharmacie |
| `calendrier-pharmacie.html` | Calendrier des contrats de la pharmacie | Pharmacie |
| `contrats.html` | Tableau des contrats ouverts, filtres, favoris, score de compatibilité | Pharmacien |
| `carte.html` | Les mêmes contrats sur une carte | Pharmacien |
| `contrat.html` (`/c/CD-XXXXXX`) | Fiche d'un contrat : postuler, contre-offrir, fil de négociation | Pharmacien |
| `disponibilites.html` | Calendrier des disponibilités du pharmacien | Pharmacien |
| `mes-mandats.html` | Mandats attribués, factures, export comptable / T2125 | Pharmacien |
| `fiche-accueil.html` | « Ce que vous devez savoir » : contact sur place, arrivée, stationnement, code de couleurs | Pharmacien + pharmacie |
| `facture-vue.html` | MANDAT / facture d'un contrat (société, TPS, TVQ lus du profil) | Les 2 parties |
| `messages.html` | Messagerie (un fil ouvert par paire, clôture mutuelle) | Les 2 parties |
| `evaluations.html` | Évaluations réciproques | Les 2 parties |
| `profil.html` | Profil complet — dont **TPS / TVQ / société** du pharmacien | Connecté |
| `nouveaux.html` (`/nouveaux/{batch}`) | Lot de contrats publiés ensemble (digest SMS) | Pharmacien |
| `admin*.html` | Console admin : vérification des comptes, contrats, blocages, KPI | Admin |
| `attente.html` | Salle d'attente tant que le compte n'est pas approuvé | Connecté |

### Flux réel

```
Pharmacie → espace-pharmacie.html#nouvelle-demande → insertion dans `contrats`
   → Worker c-direct-sms : SMS + courriel aux pharmaciens compatibles
Pharmacien → contrats.html / carte.html → /c/CD-XXXXXX → postuler OU contre-offrir
   → négociation (fil de jalons) → la pharmacie accepte
   → contrat attribué · facture (MANDAT) générée · courriel de confirmation + PDF
   → paiement Interac DIRECT de la pharmacie au pharmacien (aucune somme ne
     transite par C-Direct)
```

### Règles du réseau

Les règles qui font foi sont **en base** (table des règles, lue par le site) —
plancher horaire, taux du kilomètre, per diem et hébergement automatiques
au-delà du seuil de distance. Elles sont ré-appliquées côté serveur, donc
non contournables par l'URL.

## Base de données

Migrations numérotées dans `sql/`, à exécuter dans l'ordre via Supabase →
SQL Editor. Les plus structurantes :

- `02` schéma · `03` RLS · `04`–`05` lecture des contrats et négociation
- `07` factures · `13`–`14` distance et compatibilité (FSA)
- `18`–`19` messagerie et évaluations · `21` blocages · `23` Phase 8
- `31` correctif `accepte` (l'ancien code cherchait `acceptee`, valeur inexistante)
- `32` TPS / TVQ / société déplacés de l'ancien fichier public vers `profiles`

## Historique — pages retirées

La toute première version était un site statique sans base de données :
`demande.html` → `reponse.html` → `contre-offre.html` → `facture.html`, reliés
par paramètres d'URL et un envoi Web3Forms, avec une liste de pharmaciens
codée en dur dans `fiche.js`.

Ces pages **ne créaient aucun contrat** et étaient accessibles sans connexion.
Elles ont été supprimées ; `_redirects` renvoie les anciennes URL vers le
parcours réel. `fiche.js` a été supprimé également (il exposait publiquement
adresse, numéros de taxes et une clé d'API).

## Points de restauration

Étiquettes git `restore-phase-1` … `restore-phase-6-complete` (aucune supprimée).
Pour revenir en arrière, indiquer laquelle.

## À faire

Voir `A-FAIRE-ROBERT.md` (étapes manuelles) et `A-FAIRE-PLUS-TARD.md` (reste).
Checklist de lancement : `LAUNCH.md`.
