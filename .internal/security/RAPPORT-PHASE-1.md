# C-Direct — Bloc 1 / Phase 1 — RAPPORT DE CLÔTURE

**19 au 22 août 2026** · 22 commits · 5 migrations · Gate 1 franchi
Détail complet : `.internal/security/PHASE1-RESULTATS.md` (dans le dépôt, jamais déployé)

---

## Verdict

**Aucune fuite de données. Les trois chemins d'attaque réalistes ont été essayés en production avec de vraies sessions ; aucun n'a livré les données d'autrui.**

| Attaquant | Lire les données d'autrui | Écrire chez autrui |
|---|---|---|
| Aucune session (n'importe qui sur Internet) | **NON** — 47 tables sur 47 | **NON** |
| Locum inscrit, non approuvé | **NON** — 1 profil sur 9 | **NON** — 0 ligne modifiée |
| Pharmacie confirmée | **NON** — 1 profil sur 9 | **NON** — 0 ligne modifiée |

Le test décisif : la table `profiles` contient 9 usagers réels (noms, courriels, téléphones, permis OPQ). Chaque attaquant n'en a vu qu'**un seul** — le sien. C'est la table équivalente à celle qui a fuité chez xPayrience (414 000 dossiers) ; elle est correctement isolée, et c'est prouvé sur données réelles, pas déduit de la lecture des politiques.

Les fuites historiques `sql/63` et `sql/73` sont confirmées **fermées en production** : `get_contrats_ouverts`, `get_contrat_fiche`, `aa_horaire_libre`, `get_stats_pharmacien` et `get_note_profil` refusent tous un appelant anonyme.

**Aucune donnée n'a été modifiée pendant l'audit.** Les sessions de test ont été effacées du navigateur après coup.

---

## Ce qui était cassé et qui est maintenant réparé

### 🔴 Les frais de plateforme étaient à 0 $ en production
`frais_plateforme()` renvoyait `0`. `sql/82` sème la valeur à 0 pour la phase de test et personne ne l'avait remontée. **Le site aurait facturé 0 $ sur chaque quart.**
→ **Réglé : 9,99 $**, vérifié en production. *(Note : le reste de la documentation du projet — dont le seuil de rentabilité face à « Pas une agence » — est bâti sur 39 $.)*

### 🔴 La réinitialisation de mot de passe ne fonctionnait pas
`cdirect.quebec` manquait dans la liste blanche des redirections Supabase. Supabase ignorait alors **silencieusement** le `redirectTo` et renvoyait le jeton sur l'accueil, qui ne le traite pas. **Tout usager ayant oublié son mot de passe restait bloqué dehors.**
Le code était correct — c'était de la configuration. Trouvé uniquement parce qu'on a *essayé* de se connecter ; aucune relecture de code ne l'aurait révélé.
→ **Réglé et vérifié de bout en bout.**

### 🔴 Des documents internes étaient publiés sur le site
`/media/911/` — dossier de refonte de 845 Ko, specs, matériel promo — était téléchargeable par n'importe qui.
→ **Réglé :** déplacé dans `.internal/`, dossier en point que Cloudflare ne déploie jamais, + **garde CI** qui fait échouer le build si un document interne réatterrit à un chemin public. *(Testée : elle attrape bien une régression volontaire.)*

### 🟠 Le bucket des photos acceptait n'importe quoi
« Any » type de fichier jusqu'à 50 Mo dans un bucket public — les contrôles de `profil.html` (3 types d'images, 2 Mo) sont côté navigateur, donc contournables. Risque : hébergement d'hameçonnage ou de script sur votre infrastructure.
→ **Réglé :** 2 Mo + png/jpeg/webp au niveau du bucket, **bucket rendu privé**, affichage par URL signée. SVG volontairement exclu (une image qui peut porter du script).

### 🟡 Le dispensaire était invisible pour Google
La politique `articles` avait l'air d'ouvrir les articles publiés à tous, mais `anon` n'a pas le droit d'exécuter `est_admin()` : la requête entière échouait. Zéro article visible par un visiteur déconnecté.
→ **Réglé** (deux tentatives : la vraie coupable était une politique `FOR ALL`, qui couvre aussi la lecture). Anon passe de 401 à 200, aucun brouillon exposé.

### 🟡 Un lien de courriel périmé ressemblait à une panne
`otp_expired` s'affichait comme une erreur brute en anglais sur une page d'accueil. Indistinguable d'un site cassé — ça m'a trompé moi-même une fois.
→ **Réglé :** écran bilingue « LIEN EXPIRÉ » avec la bonne suite selon le contexte.

### 🟠 La redirection de domaine allait à l'envers
`c-direct.ca` renvoyait vers `cdirect.quebec` : le domaine sur lequel la marque est bâtie cédait son trafic et son indexation à l'autre.
→ **Réglé :** l'inverse est en place, chemin préservé, aucune boucle.

---

## Ce qui a été vérifié et qui allait bien

- **Aucun secret n'a jamais été commité** sur les 423 commits de l'historique. La clé `service_role` n'apparaît que côté serveur, jamais dans le code client.
- **47 tables sur 47 ont RLS activé.** Aucune table créée sans protection.
- **Aucune table fantôme** : le schéma live correspond exactement aux migrations. Rien n'a été créé à la main dans le tableau de bord. *(Conséquence utile : la barrière migrations de la phase 2 suffira à gouverner tout le schéma.)*
- **Les tables de paiement n'ont aucune politique d'écriture client** — seul le Worker y touche. Un usager ne peut pas s'attribuer un identifiant Stripe.
- **L'identité des pharmacies reste masquée avant confirmation**, appliqué par la base et pas seulement par l'interface.
- **Un usager déconnecté ne peut atteindre aucune page connectée.**

---

## Livré

| | |
|---|---|
| Migrations | `sql/91` → `sql/95` |
| Suite d'audit | `.internal/security/rls-adversarial-audit.mjs` + gabarit de configuration |
| Rapport détaillé | `.internal/security/PHASE1-RESULTATS.md` |
| Garde CI | `.github/scripts/asset-guard.mjs` + workflow (active, verte) |
| Journal des pannes | section ajoutée à `FIXLOG.md` |

---

## Reste ouvert

1. **Test bout en bout de la photo de profil** — *reporté sur votre décision.* Le bucket est vide, donc téléversement → affichage signé n'a jamais été parcouru ensemble. Risque limité au cosmétique.
2. **Frais à 9,99 $ vs 39 $** — la valeur est en place ; l'écart avec la documentation est signalé, pas tranché.
3. **`cdirect.ca`** (la faute de frappe évidente du domaine) — à enregistrer si disponible. Pas urgent.

Aucun de ces trois points ne bloque le Bloc 2.

---

## Ce que l'audit a appris sur la méthode

Les trois pannes les plus graves — frais à 0 $, réinitialisation cassée, documents internes publiés — **n'auraient été trouvées par aucune relecture de code.** Il a fallu interroger la production et essayer de se connecter pour de vrai. La frustration de ne pas réussir à ouvrir une session *était* le rapport de bogue.

À l'inverse, un constat signalé au départ (« la session est perdue après confirmation du courriel ») s'est révélé **ne pas être un bogue** après vérification du code : `signUp()` faisait déjà ce qu'il fallait. Écrire un correctif aurait ajouté du code inutile pour un problème inexistant.
