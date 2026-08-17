# AUDIT — Phase 0 · Refonte visuelle C-Direct

**Date :** 16 août 2026
**Portée :** lecture seule. Aucun fichier de production modifié.
**Point de retour :** `git tag refonte-phase-0-avant` → `98ea237`
**Retour arrière :** `git reset --hard refonte-phase-0-avant` (rien à annuler pour l'instant : seul `AUDIT.md` a été créé)

---

## Résumé exécutif — les 7 constats qui changent le plan

| # | Constat | Impact |
|---|---|---|
| 1 | **`logo-crochet.svg` n'existe pas.** Le fichier nommé en Partie 0.3 et 2.4 est absent du dépôt. Les logos réels sont `logo-primary.svg`, `logo-inverse.svg`, `logo-mono-*.svg`, `logo-balance-*.svg`. | Zone interdite à renommer. Hex extraits quand même (§3). |
| 2 | **Le site est en thème SOMBRE sur 9 pages publiques**, clair sur les 26 autres. `apple-dark.css` est un calque de 226 lignes qui contient **exactement** ce que la Partie 2.3 bannit : lueur radiale, glassmorphism, dégradé de texte, ombres 60 px, rayons 99 px. | C'est un **arbitrage, pas un nettoyage**. Décision requise. |
| 3 | **Les pages applicatives sont déjà en langage « étiquette ».** IBM Plex Mono domine (444 occurrences), rayons ≤ 6 px majoritaires. Le système de la Partie 2 ne les révolutionne pas — il les codifie. | Phases 2–4 beaucoup moins risquées que prévu. |
| 4 | **La page d'accueil réelle (`index.html`) n'est pas la page refaite récemment.** La refonte des 10 derniers commits est `acces.html` (Connexion, 15 août). `index.html` n'a pas bougé visuellement depuis le 10 août. | La question de la Partie 6 §7 vise probablement la mauvaise page. Décision requise (§8). |
| 5 | **Aucune police n'est auto-hébergée.** 33 pages sur 35 appellent Google Fonts. Il n'y a pas de dossier `/fonts/`. **Archivo n'est chargée nulle part.** | La Partie 2.5 est un chantier à part entière, pas un détail de la Phase 1. |
| 6 | **La base mobile de la Partie 4 est à zéro.** `viewport-fit=cover` : 0/35. `100dvh` : 0. `env(safe-area-inset-*)` : 0. `aria-live` : 0. | Phase 5 est du travail neuf sur 35 pages, pas une passe de polissage. |
| 7 | **Le sélecteur FR/EN n'existe que sur `index.html`.** Les 34 autres pages appliquent la langue mémorisée mais n'offrent aucun moyen d'en changer. | Contredit la Partie 0.4 (« sélecteur permanent dans la barre du haut »). |

---

## 1. Inventaire des pages (35 fichiers HTML)

### Public / marketing — 10 pages

| Page | Rôle | Thème |
|---|---|---|
| `index.html` | Accueil marketing (la vraie page d'accueil) | **Sombre** |
| `acces.html` | Connexion + inscription | **Sombre** + 4 correctifs locaux |
| `attente.html` | Compte en attente de validation | **Sombre** |
| `faq.html` | Foire aux questions | **Sombre** |
| `regles.html` | Règles du réseau | **Sombre** |
| `conditions.html` | Conditions d'utilisation | **Sombre** |
| `confidentialite.html` | Politique de confidentialité | **Sombre** |
| `locums-confiance.html` | Landing — argumentaire pharmacies | **Sombre** |
| `pharmacies.html` | Landing — réservation remplaçants | Clair |
| `irremplacable.html` | Page campagne « Irremplaçable » | Autonome (aucun CSS partagé) |

### Côté LOCUM — 8 pages

| Page | Rôle | Thème |
|---|---|---|
| `contrats.html` | **Liste des contrats disponibles — l'écran principal du produit** | Clair |
| `contrat.html` | Fiche contrat détaillée (URL citable `/c/CD-XXXXXX`) | Clair |
| `carte.html` | Vue carte des contrats (Leaflet) | Clair |
| `nouveaux.html` | Lot de nouveaux contrats (digest SMS) | **Sombre** |
| `disponibilites.html` | Mes disponibilités | Clair |
| `mes-mandats.html` | Mes mandats & factures | Clair |
| `pharmacies-preferees.html` | Pharmacies préférées | Clair |
| `finances.html` | Finances | Clair |

### Côté PHARMACIE — 4 pages

| Page | Rôle | Thème |
|---|---|---|
| `espace-pharmacie.html` | Espace pharmacie (publier, suivre) | Clair |
| `calendrier-pharmacie.html` | Calendrier de la pharmacie | Clair |
| `facture-vue.html` | Facture | Clair |
| `fiche-accueil.html` | Fiche d'accueil (garde `role === 'pharmacie'`) | Clair |

### Partagé — 5 pages

`profil.html` · `parametres.html` · `messages.html` · `evaluations.html` · `dispensaire.html` — toutes claires, toutes avec branchement par rôle.

### Admin — 7 pages

`admin.html` · `admin-login.html` · `admin-shifts.html` · `admin-utilisateur.html` · `admin-verification.html` · `admin-messages.html` · `admin-articles.html` — toutes claires, **zéro i18n** (voir §6).

### Orphelin — 1 page

`c-direct-accueil.html` — aucun `<h1>`, ne charge ni `design.css` ni `auth.js`, doublon apparent de `irremplacable.html`. **Non référencé par `sitemap.xml`.** À confirmer : mort ou vivant ?

---

## 2. Hex exacts du logo

Le fichier `logo-crochet.svg` nommé dans le brief **n'existe pas**. Valeurs extraites de `logo-primary.svg` (identiques dans `logo-balance-final.svg`) :

| Rôle | Hex réel du logo | Repli du brief | Écart |
|---|---|---|---|
| Vert | **`#0D2B24`** | `#14532D` | Le vrai vert est nettement plus sombre et plus froid (pétrole, pas forêt) |
| Or / ambre | **`#C98A2B`** | `#C2870B` | Le vrai or est plus clair et plus rose |
| Papier (inverse) | **`#FAFAF7`** | `#FAFAF8` | Écart négligeable — le repli est bon |

`logo-mono-black.svg` est en `#000000` pur, `logo-inverse.svg` en `#FAFAF7` + `#C98A2B`.

**À noter :** `#0D2B24` et `#C98A2B` sont **déjà présents 38 fois chacun** dans le code — mais **pas** comme couleurs de marque. Le vert dominant du site est `#0B6E4F` (« Sapin », 58 occurrences) et l'ambre dominant est `#C97B12` (36 occurrences). Le logo et l'interface ne parlent pas la même langue aujourd'hui.

---

## 3. État du thème actuel — **MIXTE**

**Trois calques, dans cet ordre :**

1. `<style>` inline de chaque page (16 à 216 lignes ; 2 942 lignes au total)
2. `/design.css` (254 lignes) — charté sur 31 pages — palette claire, `--vert:#0B6E4F`
3. `/apple-dark.css` (226 lignes) — charté sur **9 pages publiques** — inverse tout en sombre avec `!important`

`apple-dark.css` contient, textuellement, la liste des interdits de la Partie 2.3 :

| Interdit (Partie 2.3) | Présent dans `apple-dark.css` |
|---|---|
| Halos lumineux | `body::before` — `radial-gradient` de 120vw × 80vh (l.40-50) |
| Glassmorphism | `backdrop-filter:blur(20px) saturate(1.8)` (l.56) |
| Dégradés de texte | `linear-gradient(92deg,#3ADD9A…)` + `background-clip:text` (l.78-84) |
| Ombres floues diffuses | `0 24px 60px rgba(0,0,0,.5)` (l.196), `0 12px 32px rgba(0,0,0,.35)` (l.95) |
| Rayons ≥ 16 px | `border-radius:20px` (l.94), `24px` (l.193), `99px` (l.108, 174, 180, 187) |

`acces.html` lutte déjà contre ce calque : 4 blocs d'override locaux commentés « neutralise… », « ré-éclaire… », « override local » (l.119-160). C'est le symptôme d'un calque qui ne veut plus être là.

---

## 4. Recensement des valeurs codées en dur

Périmètre : 35 HTML + `design.css` + `apple-dark.css`.

### Couleurs — 844 occurrences hex, **120 valeurs distinctes** (+ 396 `rgba()`, 120 distinctes)

| Hex | Occ. | Ce que c'est |
|---|---|---|
| `#FFF` / `#FFFFFF` | 155 | Blanc (deux écritures pour la même couleur) |
| `#0B6E4F` | 58 | Vert « Sapin » — le vert réellement utilisé |
| `#1B2622` | 40 | Encre |
| `#D5E3DB` | 39 | Filet verdâtre |
| `#0D2B24` | 38 | **Vert du logo** |
| `#C98A2B` | 38 | **Or du logo** |
| `#C97B12` | 36 | Ambre d'interface (≠ or du logo) |
| `#FAFBF9` | 36 | Fond « Lin » |
| `#C0392B` | 36 | Rouge |
| `#5A6B63` | 35 | Gris « Pierre » |
| `#0E8A62`, `#084C37`, `#0D8A61` | 47 | **Trois verts supplémentaires** |
| … | | 108 autres valeurs |

**Il y a au minimum 5 verts et 2 ambres en circulation.** C'est le gisement principal de la Phase 1.

### Familles de police — 17 déclarations distinctes

| Occ. | Famille |
|---|---|
| **458** | `IBM Plex Mono` (deux écritures, dont 14 échappées `\'IBM Plex Mono\'`) |
| 64 | `Instrument Sans` |
| 44 | `Inter` |
| 31 | `Bricolage Grotesque` |
| 11 | `SF Mono`/`Roboto Mono`/Menlo |
| 8 | `Arial Narrow`/`Helvetica Neue Condensed`/Impact |
| 2 | `Anton` (logo — conforme au brief) |

**Archivo : 0 occurrence.** La police de titre du brief n'existe pas dans le projet.
**Aucune police auto-hébergée** — 33/35 pages appellent `fonts.googleapis.com`. Aucun dossier `/fonts/`.

### Tailles de police — 795 occurrences, **34 valeurs distinctes**

Dominantes : `12.5px` (105), `11px` (101), `12px` (98), `13px` (78), `15px` (77), `14px` (48), `10.5px` (46), `10px` (45), `11.5px` (33), `13.5px` (26).

Les demi-pixels (`12.5`, `10.5`, `11.5`, `13.5`, `14.5`, `9.5`, `8.5`, `7.5`) représentent **243 occurrences** — aucune n'existe dans l'échelle de la Partie 2.5.

### Rayons de coin — 401 occurrences, **25 valeurs distinctes**

| Rayon | Occ. | Verdict vs plafond 10 px |
|---|---|---|
| `4px` | 71 | Conforme |
| `5px` | 62 | Conforme |
| `8px` | 44 | Conforme |
| `3px` | 35 | Conforme |
| **`99px`** | **33** | Pilules — hors système |
| `6px` | 27 | Conforme |
| `7px` | 26 | Conforme |
| **`50%`** | **24** | Cercles — hors système (tolérable pour avatars) |
| `10px` | 17 | Conforme (plafond) |
| **`12px`–`20px`** | **38** | Hors système |

**Bonne nouvelle : 282 des 401 rayons (70 %) sont déjà ≤ 10 px.** Les 95 hors système sont concentrés sur les pages marketing et dans `apple-dark.css`.

### Ombres portées — 59 occurrences, 39 distinctes

Dont `0 8px 30px rgba(0,0,0,.35)` (×4), `0 14px 40px rgba(8,76,55,.08)`, `0 30px 80px rgba(0,0,0,.28)`. Toutes hors du système « une seule ombre, réservée aux modales ».

---

## 5. Couverture i18n

**Mécanisme réel :** attributs `data-fr` / `data-en` sur les éléments, appliqués par `auth.js` (l.1106-1131), avec les variantes `data-fr-ph` (placeholders), `data-fr-title` (infobulles), `data-fr-contenu` (meta). Il n'y a **pas** de fichier de clés — donc pas de « clé à ajouter en FR et EN » au sens du brief, mais une paire d'attributs à poser sur chaque élément.

**Parité FR/EN : parfaite. 781 `data-fr` / 781 `data-en`, zéro orphelin.** C'est propre.

**Couverture, en revanche, très inégale :**

| Niveau | Pages | Détail |
|---|---|---|
| Bon | `index` (117), `parametres` (84), `contrat` (74), `mes-mandats` (72), `profil` (67), `acces` (59), `contrats` (47), `espace-pharmacie` (45), `faq` (37) | |
| Partiel | `disponibilites` (29), `calendrier-pharmacie` (21), `locums-confiance` (21), `pharmacies-preferees` (20), `carte` (19), `facture-vue` (14), `finances` (14), `attente` (10), `nouveaux` (10), `dispensaire` (7), `fiche-accueil` (4) | |
| **Quasi nul** | `evaluations` (1), `messages` (1) | Pages entières en français dur |
| **Zéro** | `admin*` (7 pages), `conditions`, `confidentialite`, `regles`, `pharmacies`, `irremplacable`, `c-direct-accueil` | 13 pages |

**Deux problèmes structurels :**

1. **Le sélecteur FR/EN n'existe que sur `index.html`** (`<div class="lang">`). Les 34 autres pages chargent bien le moteur via `auth.js` — la langue *persiste* — mais l'utilisateur ne peut la *changer* nulle part ailleurs. La Partie 0.4 décrit « un sélecteur permanent dans la barre du haut » : il n'existe pas.
2. **7 pages ne chargent pas `auth.js`** (`index`, `pharmacies`, `regles`, `conditions`, `confidentialite`, `irremplacable`, `c-direct-accueil`) — donc aucun moteur i18n. `index.html` a le sien en inline ; les 6 autres n'ont rien.

Conformément à la Partie 0.4, **rien n'a été corrigé.** Les chaînes en dur restent en place.

---

## 6. Page d'accueil — analyse et conflit

### Levée d'ambiguïté d'abord

Le brief dit « la page d'accueil a été refaite récemment ». **Ce n'est pas ce que dit le dépôt.**

- `index.html` (l'accueil marketing) : dernier changement **visuel** le 10 août (kit crochet). Les 3 commits du 12 août sont de l'i18n et des meta.
- `acces.html` (Connexion) : **10 commits de refonte visuelle le 15 août**, dont « filet ambre sous la signature », « titre agrandi », « boutons plus hauts ». C'est le fichier le plus récemment modifié du dépôt.

**Les deux sont analysées ci-dessous, parce que la recommandation diffère selon celle que tu visais.**

### `index.html` — l'accueil marketing

| Dimension | Valeur constatée | Vs système « étiquette » |
|---|---|---|
| Palette | `--vert:#0B6E4F`, `--ambre:#C97B12`, `--encre:#1B2622`, `--blanc:#FAFBF9`, `--ligne:#D5E3DB` | **Conflit** — ni le vert ni l'ambre du logo |
| Polices | Bricolage Grotesque (14), Instrument Sans (8), IBM Plex Mono (15), Inter — 4 familles Google | **Conflit** — Bricolage n'est pas au système |
| Titre héros | `clamp(46px, 9.4vw, 144px)` | **Conflit franc** — 144 px contre 26 px au `--t-h1` |
| Rayons | `14px` ×4, `99px` ×3, `50%` ×3, `16px`, `12px` — **zéro rayon ≤ 6 px** | **Conflit** — plafond de 10 px dépassé partout |
| Ombres | 6 ombres diffuses, jusqu'à `0 30px 80px rgba(0,0,0,.28)` | **Conflit** |
| Densité | Sections héro pleine largeur, aérées | **Conflit** — Partie 2.3 bannit le héros pleine hauteur |
| Thème | **Sombre** (`apple-dark.css`) | Décision en attente |

**Verdict : le conflit est réel et total.** `index.html` parle une autre langue que le reste du produit.

### `acces.html` — la Connexion refaite le 15 août

| Dimension | Valeur constatée | Vs système « étiquette » |
|---|---|---|
| Rayons | `5px` ×7, `4px` ×4, `6px`, `8px`, `10px` — **12 rayons ≤ 6 px**, un seul écart (`clamp(18px,2vw,28px)`) | **Compatible** |
| Or du logo | `#C98A2B` ×3, dont le **filet ambre** ajouté au commit `ea56869` | **Déjà conforme à la Partie 2.2** |
| Anton | Réservée au logo | **Conforme à la Partie 2.5** |
| IBM Plex Mono | 23 occurrences | **Conforme** |
| Thème | Sombre, mais avec 4 blocs d'override qui le neutralisent localement | Symptomatique |

**Verdict : aucun conflit. `acces.html` est déjà à ~80 % dans le système de la Partie 2** — elle a même inventé le filet ambre avant que le brief ne le formalise.

---

## 7. Contradictions internes du brief — à trancher avant la Phase 1

Cinq points où le document se contredit ou contredit le dépôt. Aucun n'a été résolu unilatéralement.

**7.1 — L'ambre en texte.** La Partie 3.2 demande un badge « Comble vite » en ambre, Plex Mono **11 px**. La Partie 5 interdit l'ambre pour du texte **sous 16 px** sur fond clair. Mesures :

| Couleur | Sur blanc | AA normal (4.5:1) | AA grand (3:1) |
|---|---|---|---|
| `#C98A2B` (or du logo) | **2.94:1** | ÉCHEC | **ÉCHEC** |
| `#C97B12` (ambre actuel) | 3.32:1 | ÉCHEC | OK |
| `#C2870B` (repli du brief) | 3.10:1 | ÉCHEC | OK |

L'or du logo échoue **même en grand texte**. Le badge ambre est impossible tel que spécifié. Il faut soit un ambre assombri pour le texte (un `--ambre-texte` distinct du `--ambre` décoratif), soit un badge à texte encre sur fond ambre pâle.

**7.2 — Le vert du logo n'est pas le vert du brief.** Le repli `#14532D` est proche du vert du logo ; mais le site tourne sur `#0B6E4F`, un vert franchement plus clair et plus saturé (6.03:1 contre 14.48:1). Adopter `#0D2B24` **assombrit visiblement toute l'interface**. Ce n'est pas un remplacement neutre.

**7.3 — La Phase 1 promet « zéro changement visuel ». C'est impossible tel quel.** Remplacer une valeur par un token n'est neutre que si la valeur est identique. Or le brief demande d'installer `--vert-foret: #0D2B24` alors que le code utilise `#0B6E4F`. Soit la Phase 1 tokenise les valeurs **actuelles** (vraiment zéro changement, et on recolorise en Phase 2), soit elle change la palette et il faut abandonner la promesse. **Je recommande la première.**

**7.4 — `logo-crochet.svg` est en zone interdite mais n'existe pas.** La zone interdite devrait viser `logo-primary.svg`, `logo-inverse.svg`, `logo-mono-black.svg`, `logo-mono-white.svg`, `logo-balance-final.svg`, `logo-balance-inverse.svg` et le dossier `marque/`.

**7.5 — La Partie 0.3 protège « la structure des deux barres de navigation ».** Il y a en réalité **trois** structures d'en-tête : la `.topbar` applicative (28 pages via `auth.js`), l'en-tête marketing de `index.html` (avec hamburger sous 860 px), et les en-têtes autonomes de `irremplacable.html` / `c-direct-accueil.html`. Confirmer lesquelles sont gelées.

---

## 8. Base mobile et accessibilité (référence avant travaux)

| Exigence | État actuel |
|---|---|
| `viewport-fit=cover` (Partie 4) | **0 / 35 pages** |
| `100dvh` au lieu de `100vh` | **0 usage de `100dvh`** ; `100vh` présent sur ≥ 12 pages |
| `env(safe-area-inset-*)` | **0 usage** dans tout le dépôt |
| `aria-live` sur erreurs et toasts (Partie 5) | **0 page** |
| `outline:none` sans remplacement | Présent sur **12 pages** |
| Contraste — `#0B6E4F` sur `#FAFBF9` | 6.03:1 — OK |
| Contraste — `#0E8A62` (vert-vif) sur blanc | **4.35:1 — ÉCHEC** en texte normal |
| Contraste — `#5A6B63` (sourd) sur fond | 5.44:1 — OK |
| Contraste — `#C0392B` (rouge) sur blanc | 5.44:1 — OK |

La Partie 4 n'est pas une passe de polissage : c'est du travail neuf sur 35 pages.

---

## 9. Captures et mesures « avant » — fait, avec une réserve

### Ce qui a été possible

Serveur local sur `http://localhost:8080` (décision D3). Le rendu a été vérifié à **1440 px** et à **390 px**, avec les vraies polices Google Fonts chargées.

**Réserve technique :** le redimensionnement de fenêtre piloté à distance n'affecte pas le viewport réel (`innerWidth` reste à 1920). Le rendu 390 px a donc été obtenu en chargeant chaque page dans un iframe de 390 px de large — layout identique à un vrai mobile, mais la capture d'écran englobe la fenêtre entière. Les captures existent et sont exploitables ; elles ne sont pas au format « une image = une page » qu'imaginait la Partie 0.5.

**Recommandation :** ne pas constituer d'archive de 70 captures maintenant. La Partie 0.5 exige un avant/après **par tâche visuelle** — des captures prises aujourd'hui seront périmées à la Phase 3. La capture se fera juste avant chaque modification, page par page.

### Ce qui reste hors de portée

**24 pages sur 35 exigent une session Supabase** et redirigent vers `acces.html?mode=conn` : les 8 pages locum, les 4 pages pharmacie, les 5 pages partagées, les 7 pages admin. S'y ajoutent **5 pages que je croyais publiques** et qui redirigent aussi : `locums-confiance.html`, `nouveaux.html`, `fiche-accueil.html`, `attente.html`, `dispensaire.html`.

**Seules 9 pages sont réellement publiques :** `index`, `acces`, `faq`, `regles`, `conditions`, `confidentialite`, `pharmacies`, `irremplacable`, `c-direct-accueil`.

Pour capturer les écrans applicatifs — dont `contrats.html`, l'écran central du produit et le sujet de la Phase 3 — il faudra une session de test.

### Mesures réelles à 390 px

| Page | Débordement horizontal | Cibles < 48 px | Champs < 16 px |
|---|---|---|---|
| `index.html` | **+109 px** | 16 / 33 | 0 |
| `irremplacable.html` | **+104 px** | 4 / 9 | 0 |
| `c-direct-accueil.html` | **+104 px** | 1 / 4 | 0 |
| `acces.html` | aucun | 7 / 45 | **16** |
| `pharmacies.html` | aucun | 7 / 9 | **10** |
| `faq.html` | aucun | 7 / 19 | 0 |
| `conditions.html` | aucun | 3 / 3 | 0 |
| `confidentialite.html` | aucun | 3 / 3 | 0 |
| `regles.html` | aucun | 2 / 2 | 0 |

**Trois pages débordent horizontalement à 390 px.** C'est un manquement au smoke check du `CLAUDE.md` (« No horizontal scrollbar at any width »), pas seulement à la Partie 4.

**`acces.html` a 16 champs sous 16 px** — iOS zoomera automatiquement à chaque mise au point. Sur la page de connexion, donc au tout premier contact avec le produit.

---

## 10. Décisions requises — STOP Phase 0

**D1 — Clair ou sombre ?**
Le brief conçoit un système clair et le justifie (argent, numéros de licence, conditions contractuelles). Le site est sombre sur ses 9 pages publiques. Options : (a) tout passer en clair et supprimer `apple-dark.css` ; (b) garder le sombre en public et le clair en app ; (c) garder le sombre partout et refaire le système en sombre.

**D2 — Le sort de la page d'accueil.**
Deux sous-questions : (i) parlais-tu d'`index.html` ou d'`acces.html` ? (ii) `index.html` entre en conflit total avec le système — l'aligner sur le système, ou dériver le système d'elle ?

**D3 — Comment produire les captures « avant » ?**
(a) Tu ouvres une session Cloudflare Access dans le navigateur, je capture la prod ; (b) tu lances `cd ~/Desktop/Projet\ 1 && python3 -m http.server 8080` et je capture ton arbre de travail réel — plus fidèle ; (c) on saute les captures et on accepte le trou.

**D4 — Les cinq contradictions du §7** — en particulier 7.1 (ambre illisible) et 7.3 (« zéro changement visuel » impossible).

**Aucun travail de Phase 1 ne commence avant réponse.**

---

## 11. Décisions prises par Robert — 16 août 2026

| # | Question | Décision |
|---|---|---|
| D1 | Clair ou sombre | **Tout en clair.** `apple-dark.css` est à supprimer. |
| D2 | Quelle page d'accueil | **`acces.html`** était la page refaite. Elle devient la **référence validée**. `index.html` reste une page à corriger comme les autres. |
| D3 | Captures « avant » | **Serveur local** sur `http://localhost:8080`. |
| D4 | Palette en Phase 1 | **Tokeniser l'existant.** Les tokens prennent les valeurs actuelles (`#0B6E4F`…). Vrai zéro changement visuel. Recolorisation vers les hex du logo en Phase 2. |

### Conséquence à traiter dès la Phase 2 — D1 × D2 interagissent

`acces.html` est à la fois **la référence validée (D2)** et **une page qui charge `apple-dark.css` (D1)**. Ses 4 blocs d'override (l.119-160) ont été écrits pour *neutraliser* le calque sombre. Supprimer `apple-dark.css` ne restaure donc pas `acces.html` dans son état voulu : ça la fait changer d'apparence, et les overrides deviennent au mieux inutiles, au pire nuisibles.

**Ordre imposé :** capturer `acces.html` telle qu'elle est aujourd'hui (rendu final validé), retirer `apple-dark.css`, puis reconstruire le rendu à l'identique en CSS clair natif, capture à l'appui. Ce n'est pas une tâche de suppression — c'est un portage. À isoler dans son propre commit.

### Conséquence à traiter — D2 × Partie 2.5 : Anton

`acces.html` est la référence validée. Elle utilise **Anton comme police de titre d'interface**, à deux endroits :

- `.cnx-porte .carte h2` — `clamp(30px, 3.4vw, 44px)` (« COMMENCER L'AVENTURE. »)
- `.cnx-titre` — `clamp(28px, 3vw, 44px)` (« Une heure et demie de route. »)

La Partie 2.5 dit : « **Anton reste réservé au logo. Il n'apparaît nulle part dans l'interface.** »

On ne peut pas tenir les deux. Soit la référence validée est amendée (Anton retiré de ces deux titres), soit la Partie 2.5 est amendée (Anton promu police d'affichage, ce qui rend Archivo largement inutile). **À trancher avant la Phase 2.**

Deux autres écarts de `acces.html` au brief, plus mineurs :

- Le filet ambre fait **46 × 3 px** ; la Partie 2.2 spécifie **40 × 2 px**.
- `#E7B054` sert d'ambre pour l'eyebrow — c'est un **troisième** ambre, après `#C98A2B` (logo) et `#C97B12` (interface).
- Animation `cnx-derive` de **9 secondes** sur la photo. La Partie 2.7 plafonne à 200 ms et bannit les animations décoratives.

### Reste ouvert

Contradictions du §7 autres que 7.3 (tranchée par D4) : **7.1 (ambre illisible en badge)**, 7.2, 7.4 (zone interdite à renommer), 7.5 (trois en-têtes, pas deux). Plus la question Anton ci-dessus. À trancher avant la Phase 2.

---

## 12. Bugs et anomalies repérés, **non corrigés**

Conformément aux Parties 0.1 et 8 :

1. `c-direct-accueil.html` — page sans `<h1>`, sans CSS partagé, absente de `sitemap.xml`. Doublon probable d'`irremplacable.html`. Mort ou vivant ?
2. `#FFF` et `#FFFFFF` coexistent (155 occurrences combinées) pour la même couleur.
3. `design.css` déclare `--jaune:#B07207` mais les pages utilisent `#C97B12` — le token est contredit à l'usage.
4. `parametres.html` charge `design.css` **3 fois** ; `nouveaux.html` le charge **2 fois**.
5. `pharmacies.html` fait **4 appels** à Google Fonts sur une seule page.
6. 14 déclarations de `font-family` avec apostrophes échappées (`\'IBM Plex Mono\'`) — probable injection depuis une chaîne JS.
7. `apple-dark.css` l.92 : `[class]{box-shadow:none}` — sélecteur d'attribut universel qui écrase toute ombre sur tout élément portant une classe. Extrêmement large.
8. `apple-dark.css` l.99-103 : sélecteurs `[style*="background:#fff"]` — dépendent de la graphie exacte du style inline. Fragile par construction.
9. `acces.html` contient 4 blocs d'override luttant contre `apple-dark.css` — dette qui disparaîtrait avec la décision D1.
10. **`index.html` déborde de 109 px à 390 px de large** — barre de défilement horizontale sur mobile. Idem `irremplacable.html` et `c-direct-accueil.html` (+104 px chacune).
11. **La mascotte (`accueil-mascotte.js`) chevauche le bouton « Je suis pharmacien remplaçant »** à 390 px sur `index.html` — la cible principale de conversion est partiellement couverte.
12. **`locums-confiance.html` exige une session** et redirige vers la connexion. Une page d'argumentaire destinée à convaincre des pharmacies est inatteignable pour un visiteur non connecté. Idem `fiche-accueil.html` et `dispensaire.html`. À confirmer : intentionnel ou régression ?
13. `acces.html` : 16 champs de formulaire sous 16 px — iOS zoome automatiquement à la mise au point, sur la page de connexion.
14. 16 des 33 éléments interactifs d'`index.html` mesurent moins de 48 px de haut à 390 px.

---

## 12 bis. Travaux réalisés le 16 août — état à la reprise

### Livré et poussé

| Phase | Commit | Contenu |
|---|---|---|
| 1 · T1 | `e55d5e6` | `tokens.css` — jetons §2.4-2.6 aux valeurs actuelles réelles (D4), préfixe `--cd-` |
| 1 · T2 | `715a99e` | `design.css` importe les jetons, `:root` exprimé via `var(--cd-*, littéral)` |
| 1 · T3 | `9e60e7d` | `_headers` : `no-cache` sur `tokens.css` |
| 1.5 · T1 | `f3168b6` | `auth.js` : prénom replié sous 430 px → fin du débordement de la topbar |
| 1.5 · T2 | `f83c76b` | `mes-mandats` : `min-width:0` sur les colonnes, `minmax(0,1fr)`, formulaire empilé |
| 1.5 · T3 | `f590a1c` | `contrats` : cadre défilant `.table-scroll` |
| 3 · T1 | `4723b0f` | Carte de contrat sous 860 px — bloc taux, filet ambre, bouton 48 px |
| 3 · T2 | `18a59b1` | Sortie des règles de carte de `@media(max-width:720px)` |
| 3 · T3 | `41ec7b2` | Bandeau de filtres repliable sous 560 px + compteur de filtres actifs |

Points de retour : `refonte-phase-0-avant`, `refonte-phase-1-avant`, `refonte-phase-1.5-avant`.

### Débordement horizontal — avant / après

| Page | 375 px | 390 px | 768 px | 1440 px |
|---|---|---|---|---|
| `contrats` | +357 → **0** | +357 → **0** | +394 → **0** | 0 |
| `mes-mandats` | +941 → **5** | +926 → **3** | +548 → **0** | +436 → **0** |
| `finances`, `carte`, `parametres`, `profil`, `disponibilites` | +43 → **0** | +28 → **0** | 0 | 0 |

### Décisions appliquées (recommandations validées par Robert)

- **Portée réduite** : Phases 1.5 et 3 livrées avant lancement ; Phases 2, 4 et 6 reportées après septembre. La couche de jetons étant en place, la recolorisation devient un changement d'une ligne par jeton.
- **Anton conservé, Archivo abandonnée.** Anton en affichage uniquement, jamais en texte d'interface. Donne les trois familles du brief — Anton / Inter / IBM Plex Mono — en supprimant Archivo, Bricolage Grotesque et Instrument Sans.
- **Badges à remplissage teinté** : fond `#FBF6EE`, bordure et texte `#9E6D22` (4,5:1). L'ambre pur `#C98A2B` mesure 2,94:1 et ne peut pas porter de texte.
- **Exemption barre de navigation** : repli et débordement sous 768 px uniquement ; destinations, ordre et libellés inchangés.
- **Cible « 3 cartes » de la §3.1 : reportée après lancement.** Décision de Robert, 16 août. La carte de contrat garde ses 237 px. Son gain — rendre le taux horaire lisible sur téléphone, le constat central de la §13.1 — disparaîtrait en la comprimant à ≤ 170 px. On accepte **2 cartes entières** au lancement plutôt que d'annuler ce gain. Aucun chiffrage n'a été demandé ni produit.

### Reste à faire — bloqué sur Robert

1. **320 px déborde de 44 px sur toutes les pages.** `.in` consomme 44 px de padding et le bloc de contrôles fait 247 px. Exige un menu hamburger — hors de l'exemption accordée.
2. **`banniere` est vide en base.** La carte §3.1 est construite pour afficher « Jean Coutu · Boucherville » et se replie sur la ville seule. Vérifier si l'inscription pharmacie collecte ce champ.
3. **Jeu de test non représentatif** : 9 contrats identiques (140 $/h, 188 km, même ville). Le comportement de la carte avec une bannière longue, un taux manquant ou une ligne de contexte courte n'est pas vérifié.
4. **Compte de test pharmacie** absent — `espace-pharmacie`, `calendrier-pharmacie`, `facture-vue`, `fiche-accueil` jamais mesurées.
5. **Contradictions §7 non tranchées** : 7.2 (vert du logo nettement plus sombre), 7.4 (zone interdite nommant un fichier inexistant), 7.5 (trois en-têtes, pas deux).

### Reste à faire — faisable sans Robert

- ~~**Bloc de filtres de `contrats.html`**~~ — **fait (Phase 3 · T3).** Voir la correction de mesure ci-dessous.
- **Champs sous 16 px** : `profil` (96), `parametres` (35), `contrat` (21), `contrats` (10) — iOS zoome à la mise au point. Relève de la Phase 5, reportée.
- **Cibles tactiles sous 48 px** : quasi universelles sur les pages applicatives. Phase 5, reportée.

### Correction de mesure — bloc de filtres (16 août, session de reprise)

Les chiffres écrits plus haut lors de la première passe étaient faux. Mesures reprises dans un cadre réel de 390 × 844, session locum ouverte, 9 contrats :

| | Écrit d'abord | **Mesuré** |
|---|---|---|
| Hauteur du bloc de filtres | ~250 px | **164 px** (4 rangées) |
| Hauteur totale au-dessus de la première carte | non mesurée | **448 px** |
| Cartes entières visibles | 2,5 | **1** (+ 63 % de la deuxième) |

**Piège rencontré :** l'onglet servait une copie en cache de `contrats.html` (débordement +357 px, zéro carte — l'état d'avant la Phase 3) alors que le fichier sur disque était à jour. Toujours forcer un rechargement matériel avant de mesurer.

**Le bloc de filtres n'était pas le verrou.** La cible « 3 cartes » de la §3.1 demande 237 × 3 + 10 × 2 = **731 px**, donc une première carte à **≤ 113 px**. Plancher mesuré en retirant *à la fois* les filtres **et** les deux rangées d'onglets : **172 px**, soit encore 2 cartes entières. Le facteur limitant est la **hauteur de carte** (237 px), pas les filtres : il faudrait descendre la carte à ≤ 170 px. Reporté après lancement par décision de Robert (voir « Décisions appliquées »).

**Ce que T3 livre réellement**, bouton de repli 44 px inclus :

| Largeur | Avant | Après |
|---|---|---|
| 375 px | 1 carte entière | **2 cartes entières** (2ᵉ finit à 842 px) |
| 390 px | 1 entière + 63 % | **2 entières** + 11 % |
| 560 px | 2 entières | 2 entières + 34 % |
| 768 px | 2 entières | **inchangé** (bouton masqué, filtres 79 px) |
| 1440 px | tableau, 9 lignes | **inchangé** |

Première carte : **448 px → 320 px**. Le repli s'arrête à 560 px parce qu'au-delà le bandeau ne fait plus que 2 rangées (79 px) — mesuré : 4 rangées jusqu'à 430 px, 3 rangées de 440 à 560 px, 2 rangées à partir de 580 px.

**Deux pièges d'implémentation, consignés pour la suite :**

1. La page pose `style="display:flex"` **en ligne** sur `#filtres` (script, ligne 1032). Toute règle `display:none` en CSS est ignorée. Le repli passe donc par `max-height`, et la ligne 1032 n'a pas été touchée.
2. `f-jsem` n'a **pas d'option vide** : sa valeur au repos est `1` (Lundi). Une première version du compteur de filtres actifs affichait donc « 1 » sur une page vierge. Le compteur suit maintenant la logique réelle de `dessiner()` : le bloc date compte pour 1 au plus, et seulement s'il retire vraiment des contrats.

Le débordement de 44 px à 320 px est inchangé — il reste suspendu à la décision hamburger.

---

## 13. Écrans applicatifs — mesures du 16 août (session locum ouverte)

### 13.1 Le constat central : le taux horaire est invisible sur téléphone

Sur `contrats.html` à 390 px, les colonnes visibles sont **RÉFÉRENCE**, **DATE**, et un fragment de **HEURES**. Les colonnes **TARIF**, **VILLE**, **LOGICIEL** et **STATUT** sont hors écran à droite.

La Partie 1 du brief dit, au sujet du pharmacien locum :

> « Ce qu'il doit lire sans réfléchir : **le taux horaire**, la date, la distance, le logiciel, la charge de travail, quand il est payé. **S'il doit ouvrir une fiche pour connaître le taux, le design a échoué.** »

Le locum est décrit debout derrière un comptoir, téléphone en main, 30 secondes. **Sur ce téléphone, il ne voit aucun taux.** Ce n'est pas un défaut introduit par la refonte : c'est l'état actuel, mesuré.

S'y ajoutent, avant le premier contrat : 6 filtres empilés sur ~130 px de hauteur, un bouton « Réinitialiser », et deux rangées d'onglets. La mascotte recouvre partiellement la 5ᵉ ligne.

### 13.2 Débordement horizontal — toutes les pages applicatives

| Page | Débordement à 390 px | Cibles < 48 px | Champs < 16 px | Tableaux |
|---|---|---|---|---|
| `mes-mandats.html` | **+926 px** | 84 / 85 | 6 | 5 |
| `contrats.html` | **+357 px** | 24 / 25 | 10 | 1 |
| `messages.html` | +96 px | 18 / 19 | 1 | 0 |
| `evaluations.html` | +96 px | 19 / 19 | 0 | 0 |
| `contrat.html` | +69 px | 13 / 13 | 21 | 0 |
| `pharmacies-preferees.html` | +68 px | 18 / 18 | 0 | 0 |
| `parametres.html` | +28 px | 33 / 34 | **35** | 0 |
| `finances.html` | +28 px | 17 / 18 | 2 | 1 |
| `carte.html` | +28 px | 25 / 25 | 3 | 0 |
| `profil.html` | +28 px | **77 / 77** | **96** | 0 |
| `disponibilites.html` | +27 px | 25 / 26 | 3 | 0 |

**Aucune page applicative ne tient dans 390 px.**

### 13.3 Deux causes, dont une partagée

**Cause 1 — la barre de navigation (~28 px sur TOUTES les pages).**
Chaîne identifiée : `.topbar` → `.in` → `.droite` → `.cd-menu-defile`. Son `scrollWidth` vaut **418 px** dans un conteneur de 380–390 px, sur chaque page testée. C'est le plancher de 27–28 px constaté partout.

**Un seul correctif partagé supprime le débordement sur 5 pages** (`finances`, `carte`, `parametres`, `profil`, `disponibilites`) et réduit d'autant les 6 autres.

⚠️ **La barre de navigation est en zone interdite (Partie 0.3).** Je n'y touche pas sans autorisation explicite. Corriger le débordement modifie son comportement de repli, ce que la Partie 0.3 gèle.

**Cause 2 — les tableaux.** Le reste du débordement vient des `<table>` non responsives : `contrats.html` (1 tableau, +357 px), `mes-mandats.html` (5 tableaux, +926 px).

### 13.4 Conséquence pour le plan d'exécution

Le brief place la passe mobile en **Phase 5**, après toute la refonte visuelle. Les mesures disent que c'est le mauvais ordre : le produit est aujourd'hui inutilisable sur le terminal de sa persona principale. Refaire l'apparence de cartes qu'on ne peut pas lire sur un téléphone revient à peindre une pièce dont le plancher est effondré.

**Recommandation :** remonter le correctif de débordement (13.3, cause 1 + les deux tableaux) **avant** la Phase 2, en une phase courte « Phase 1.5 — plancher mobile ». Elle ne change aucune couleur ni police : uniquement le repli en largeur. Décision de Robert requise, notamment parce qu'elle touche une zone interdite.

### 13.5 Bonne nouvelle : la carte du brief est constructible

La Partie 3.1 impose une carte affichant bannière, ville, distance, logiciel, volume, taux et délai de paiement. Ces données existent déjà :

- `banniere` — colonne `text` dans `sql/01-auth-profiles.sql`, 26 usages dans le code
- `delai_paiement` — 4 usages
- distance, logiciel, volume Rx, ATP — déjà affichés dans la ligne secondaire du tableau (`≈300 Rx · ATP · Seul(e)`, `≈ 1 460 $ · 188 km`)

**La Phase 3 n'est donc pas bloquée par le modèle de données.** Elle reste néanmoins une réécriture structurelle tableau → cartes, pas un simple restylage — le brief la décrit comme « la phase la plus importante du projet », ce que ces mesures confirment.
