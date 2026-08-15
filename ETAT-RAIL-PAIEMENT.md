# État réel du rail de paiement C-Direct — 15 août 2026

Réponse à l'item **C3** (« Report the real state of the Stripe payment rail: what is built, what is dormant, what is untested »). Écrit après vérification directe du code, de la base et du tableau de bord Stripe — pas de mémoire, pas de suppositions.

---

## 1. En une phrase

Le rail est **construit au complet et fonctionne en mode réel**, mais **aucun dollar n'a encore circulé** : il manque la vérification d'identité de Robert chez Stripe, sans laquelle aucun pharmacien ne peut recevoir de paiement.

---

## 2. Ce qui se passe, quart par quart

1. **À l'inscription**, la pharmacie enregistre une carte. Elle est appelée « garantie de paiement », pas « mode de paiement » — pour la plupart des pharmacies elle ne sera jamais débitée.
2. **24 h avant le quart**, le système crée automatiquement une **autorisation** sur cette carte. L'argent n'est pas prélevé : il est seulement réservé. Le propriétaire n'a rien à faire (c'est souvent son jour de congé).
3. **Le quart a lieu.** Le pharmacien soumet sa feuille de temps, la pharmacie l'approuve.
4. **La pharmacie paie** par le moyen qu'elle a choisi : Interac ou chèque (directement au pharmacien), ou carte.
5. **Le pharmacien confirme** avoir reçu le bon montant → l'autorisation est **annulée**. Coût pour la pharmacie : **0 $**.
6. **Pas de confirmation avant l'échéance** → l'autorisation est **capturée**. Le pharmacien est payé via Stripe, frais 2,9 % + 0,30 $.

L'autorisation joue donc le rôle d'un dépôt de garantie, en mieux : rien ne dort nulle part, pas même chez Stripe, et l'annuler ne coûte rien. C'est ce qui permet de garantir chaque quart au pharmacien sans jamais faire transiter son salaire par C-Direct — le point juridique central du projet.

---

## 3. Ce qui est construit et vérifié

| Élément | État |
|---|---|
| Clés Stripe en mode réel (site + Worker) | ✅ Vérifié 15 août |
| Carte pharmacie enregistrée en réel | ✅ Vérifié en base : `stripe_payment_method_id` rempli |
| Worker de paiement déployé | ✅ Version `c56a8d1f` |
| Cron automatique (aux 15 min) | ✅ Actif |
| Webhook Stripe (9 évènements, comptes connectés) | ✅ Présent, actif, signé |
| Machine à états (7 statuts) | ✅ Construite |
| Échelle de relance T-18h / SMS T-12h / escalade T-6h | ✅ Construite |
| Bouton « j'ai envoyé » côté pharmacie (+60 min) | ✅ Câblé |
| Facture du pharmacien générée automatiquement | ✅ Construite |
| Double tarification (prix carte / prix Interac) | ✅ En ligne |

**Note importante sur la sécurité :** le numéro de carte ne touche jamais les serveurs de C-Direct. Il va du navigateur directement à Stripe, dans un cadre appartenant à Stripe. La base ne contient que deux références (`cus_…`, `pm_…`), inutilisables sans la clé secrète. La table est verrouillée : lecture de sa propre ligne seulement, aucune écriture possible par un utilisateur.

---

## 4. Ce qui est volontairement dormant

Ces choix ont été faits consciemment, ils ne sont pas des oublis.

- **Carte de secours** — une seule carte par pharmacie aujourd'hui. L'échelle de relance prévoit un palier « essayer la 2e carte », mais il n'y a pas de 2e carte en base.
- **Palier « 16 h le jour ouvrable suivant »** pour les pharmacies ayant un comptable — non implémenté. **Tout le monde est sur le délai standard de 3 h.** À rouvrir avant d'accueillir des groupes de pharmacies : un quart du dimanche ne peut pas être payé par un comptable qui travaille en semaine.
- **Refroidissement 72 h sur le courriel Interac** — la table existe mais plus rien ne l'écrit ; la protection n'est donc **pas appliquée** aujourd'hui. C'est la protection anti-fraude qui empêche un compte pharmacien compromis de rediriger les paiements. À rebrancher avant l'ouverture au public.
- **Virements instantanés** — non promis nulle part, et au Canada ils exigeraient une carte de débit comme compte de dépôt.

---

## 5. Ce qui n'est pas encore testé

Rien de tout ceci n'est cassé — simplement jamais exercé avec de l'argent réel :

1. **Une capture réelle** (le cas « la pharmacie n'a pas payé »).
2. **Une annulation réelle** (le cas normal : Interac confirmé → 0 $).
3. **La livraison d'un webhook** — le compteur est à 0 livraison, ce qui est normal puisqu'aucun évènement réel n'a encore eu lieu.
4. **L'onboarding Connect d'un pharmacien en mode réel.**

---

## 6. Le seul blocage

Stripe exige une **pièce d'identité avec photo + un égoportrait** de Robert (EDOUARD ABDEL MALAK) avant d'autoriser la création de comptes connectés réels. Le message d'erreur affiché parle à tort de « platform profile / questionnaire » ; la vraie demande est visible sur https://dashboard.stripe.com/connect/accounts/overview.

Tant que ce n'est pas fait : aucun compte connecté → aucune autorisation possible → aucun test d'argent réel. C'est une vérification unique sur le propriétaire de l'entreprise, distincte de celle déjà passée pour encaisser des cartes, et distincte de celle que chaque pharmacien fera pour son propre compte.

---

## 7. Coût par quart (exemple : 10 h à 136 $/h)

| | Carte | Interac ou chèque |
|---|---|---|
| La pharmacie paie | 1 441 $ | 1 399 $ |
| Le pharmacien reçoit | 1 360 $ | 1 360 $ |
| Frais Stripe | 42,09 $ | 0 $ |
| Geste du propriétaire | aucun | une connexion bancaire |

Le pharmacien reçoit le même montant dans les deux cas. À titre de comparaison, l'écart de 20 $/h d'un concurrent coûterait 1 560 $ à la pharmacie pour ce même quart, en ne versant que 1 160 $ au pharmacien.
