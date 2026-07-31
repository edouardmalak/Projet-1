# C-Direct — Plan app mobile (App Store + Google Play)

Décision prise le 2026-07-30 : Robert veut une **vraie app native** (pas un simple
« site emballé »), sur les deux stores, avec une expérience exceptionnelle. Le
site web est terminé **d'abord**; l'app est construite après, en réutilisant
tout le backend. Le calendrier peut glisser au besoin — pas de date figée.

## Ce qui est déjà prêt pour la conversion (vérifié)

Toute la logique métier (tarifs, pénalités d'annulation, calcul de facture,
distance) vit déjà dans Supabase (fonctions RPC), pas dans le JavaScript du
site — 68 appels `sb.rpc()` répartis sur 16 pages, zéro calcul dupliqué trouvé
côté client. C'est exactement la base qu'il faut : l'app Flutter appellera les
mêmes fonctions que le site, sans reconstruire les règles métier. **Continuer
sur cette lancée** : toute nouvelle logique (paiements Stripe compris) doit
rester dans Supabase, jamais dans le JS d'une page.

## Ce qu'il reste à préparer — par catégorie

### A. Règle Apple qui touche directement le système de paiement
Apple exige normalement que les achats passent par son propre système
(Apple In-App Purchase, 30 % de commission) — **mais** les apps qui vendent un
**service réel** (Uber, Airbnb, DoorDash) en sont exemptées et utilisent leur
propre processeur (ici Stripe). C-Direct devrait être dans cette catégorie
(paiement d'un quart de travail réel entre deux parties). Risque faible mais
à documenter explicitement dans les notes de soumission Apple le jour venu —
le même argument légal déjà retenu pour éviter la classification « agence »
(« C-Direct transmet une facture entre deux parties ») sert aussi ici.

### B. À préparer sur le site MAINTENANT (pendant qu'on le termine)
- **Liens profonds (deep links)** : les courriels/SMS envoient déjà des liens
  vers des pages précises (contrat confirmé, facture, clavardage). Pour que
  ces liens ouvrent l'app plus tard au lieu du navigateur, le site doit
  héberger deux petits fichiers de vérification
  (`apple-app-site-association`, `assetlinks.json`). Peut être mis en place
  dès maintenant, sans attendre l'app.
- Garder toute nouvelle logique dans Supabase (voir ci-dessus).

### C. Comptes que seul Robert peut créer (pur temps d'attente — à démarrer tôt)
- **Apple Developer Program** — 99 $ US/an, vérification d'identité (peut
  prendre quelques jours si compte « entreprise »).
- **Google Play Developer** — 25 $ US, une fois.

### D. Détails qui feront rejeter l'app si oubliés
- **« Sign in with Apple »** obligatoire si l'app offre Google Sign-In —
  sinon Apple refuse l'app.
- **Suppression de compte depuis l'app** — Apple exige que l'utilisateur
  puisse supprimer son compte dans l'app, pas juste par courriel.
- **Politique de confidentialité publique** + questionnaire sur les données
  collectées (l'app touche noms, numéros OPQ, infos de paiement — pas un
  détail).

### E. Changement de rythme à comprendre
Aujourd'hui, chaque `git push` est en ligne en quelques secondes. Une fois
l'app publiée, chaque mise à jour repasse par une révision du store
(généralement 1-3 jours une fois approuvé la première fois, plus long pour
la toute première soumission). On ne pourra plus « patcher » l'app aussi vite
que le site.

### F. Travail de design à prévoir (séparé du code)
« Exceptionnel » veut dire une vraie interface native (styles Apple/Google),
pas le CSS du site recopié tel quel. À prévoir comme un chantier à part.

### G. Pour plus tard, une fois la construction de l'app commencée
- Certificat push Apple (APNs) + projet Firebase (Android) — rien à faire
  avant de commencer l'app.
- Accès à un Mac (ou service cloud type Codemagic) pour compiler/soumettre
  côté iOS — je ne peux pas compiler d'app iOS moi-même.
- Icône, captures d'écran par taille d'appareil, description, mots-clés —
  travail de fin de projet.

## Prochaine étape concrète
Continuer le site (aucune action bloquée par ce qui précède). Le seul geste
utile dès maintenant côté Robert : démarrer l'inscription Apple Developer,
puisque c'est pur délai d'attente.
