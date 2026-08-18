# Plan — paiement instantané, pointage et modification des heures

**Statut : PROPOSITION — rien n'est construit. À valider avant toute ligne de code.**
Rédigé le 2026-08-18 d'après les décisions de Robert du même jour.

---

## 1. Les décisions déjà prises

| Question | Décision |
|---|---|
| « Débit » | **Carte de débit au paiement** (Visa Débit / Débit Mastercard) |
| Attente de paiement | **Interdite** — chaque paiement doit être instantané |
| Frais au pharmacien | **Interdits** — il reçoit son montant, net, toujours |
| Frais de plateforme | Robert refait sa grille pour absorber le 1 % |
| Interac | **Retiré pour les premiers mois** |
| Chèque | **Conservé en repli**, avec confirmation du pharmacien |
| Photo + position au pointage | **Vérifier puis jeter** — on ne garde que réussi/échoué + horodatage |
| Heures différentes du contrat | **Les deux parties approuvent** avant tout prélèvement |

### La bonne nouvelle : « débit » ne demande aucun travail

Visa Débit et Débit Mastercard circulent sur les réseaux de cartes. Le rail
Stripe **actuel les accepte déjà**. Aucun fournisseur à ajouter, aucun code à
écrire, aucune exposition juridique nouvelle. Une pharmacie qui paie par carte
de débit fait un paiement par carte ordinaire, qui se règle directement sur le
compte connecté du pharmacien.

### Ce qui reste impossible, et pourquoi

**VoPay est écarté, et ce n'est pas une préférence.** Leur Interac Money Request
règle dans un compte groupé VoPay avec C-Direct comme *demandeur de record* :
C-Direct devient le payé. Leur modèle Payfac-as-a-Service ferait de C-Direct le
facilitateur de paiement, avec inscription FINTRAC comme ESM, permis AMF,
inscription RPAA et programme complet de lutte au blanchiment. Ils ne traitent
pas les cartes de crédit non plus. Zūm Rails, Paysafe, Nuvei et le débit
préautorisé tombent pour la même raison de garde des fonds.

Le constat de fond : **tout rail bancaire de type « pull » nomme son payé dans
le mandat**, donc le mandat ne peut pas être pointé vers le pharmacien. La carte
est le seul rail canadien où une plateforme peut orchestrer un paiement qui se
règle directement chez un tiers sans jamais être le payé.

---

## 2. Le déroulé proposé, quart par quart

```
T-24 h    Autorisation carte créée automatiquement (EXISTE DÉJÀ)
          -> la garantie de paiement, inchangée

Arrivée   Le pharmacien POINTE L'ARRIVÉE
          photo + position -> vérifiées -> jetées
          on ne garde que : reussi/echoue + horodatage

Départ    Le pharmacien POINTE LE DÉPART
          -> c'est CE geste qui déclenche le financement

          Heures pointées = heures du contrat ?
            OUI  -> prélèvement immédiat -> virement instantané (~30 min)
            NON  -> avenant proposé, montant recalculé
                    -> les DEUX approuvent
                    -> puis prélèvement -> virement instantané

Chèque    La pharmacie remet un chèque sur place
          -> le pharmacien confirme « reçu, montant exact »
          -> l'autorisation est ANNULÉE (0 $ prélevé)
```

---

## 3. Ce qu'il faut construire

### Phase 1 — Virement instantané (le cœur de la promesse)

- **Réglage Stripe (Robert, tableau de bord)** : Paramètres → Connect → Paiements
  → Comptes externes → « Allow debit cards? » → **Oui**. Aucun code ne peut le
  faire à notre place.
- **Onboarding pharmacien** : collecter une **carte de débit** comme compte
  externe. Au Canada, Stripe ne fait PAS de virement instantané vers un compte
  bancaire — carte de débit obligatoire. Un pharmacien sans carte de débit ne
  peut pas être payé instantanément, jamais.
- **Code** : après le prélèvement, lire le solde avec
  `expand[]=instant_available.net_available`, vérifier que le compte externe
  a bien `instant` dans `available_payout_methods`, puis créer le virement avec
  `method=instant`.
- **Coût** : 1 % du montant viré, facturé à la plateforme. Sur un quart de
  1 360 $, **13,60 $**. Robert refait sa grille en conséquence.
- **Bornes** : minimum 0,60 $ CA, maximum 9 999 $ CA par virement.

> ⚠️ **À valider avec Stripe avant de le promettre publiquement.** Stripe ne
> rend PAS les nouveaux comptes connectés admissibles au virement instantané
> immédiatement : il y a une montée en charge selon le volume traité et l'âge du
> compte. Chaque plateforme a aussi un plafond quotidien de virements instantanés
> tous comptes confondus. « Toujours instantané, dès le premier jour » n'est donc
> pas garanti par Stripe. À confirmer directement avec eux.

### Phase 2 — Pointage arrivée / départ

- Nouvelle table `pointages` : candidature, type (arrivee/depart), horodatage,
  `position_conforme` (booléen), `photo_fournie` (booléen). **Ni image ni
  coordonnées en base.**
- Écran pharmacien : bouton Pointer l'arrivée / Pointer le départ.
- Vérification de la position dans un rayon autour de la pharmacie, faite au
  moment du pointage ; le résultat seul est conservé.
- Vue pharmacie : qui est arrivé, à quelle heure, présence confirmée ou non.

### Phase 3 — Avenant et double approbation

- Comparaison heures pointées / heures contractées.
- Si écart : avenant proposé avec le montant recalculé, à approuver par les deux.
- Le prélèvement ne part qu'une fois les deux approbations obtenues.
- Puis Phase 1 s'enchaîne : prélèvement → virement instantané.

### Phase 4 — Interac coupé, chèque conservé

- Interrupteur admin (même patron que les frais de plateforme) : Interac éteint
  par défaut. Le code et la machine à états restent en place, dormants.
- Le chèque garde la confirmation du pharmacien qui annule l'autorisation.

---

## 4. Trois trous à boucher — mes valeurs par défaut proposées

Ces cas n'ont pas été tranchés. Voici ce que je propose ; à corriger si besoin.

**a) La pharmacie n'approuve pas l'avenant.**
Le pharmacien attendrait son argent indéfiniment, ce qui contredit « attendre
n'est pas une option ». Proposition : **délai de 3 heures**, puis prélèvement
automatique du **moindre** des deux montants (contrat ou heures pointées), viré
instantanément. On ne prélève jamais plus que le montant déjà accepté sans
approbation, et le pharmacien est payé. L'écart restant devient une réclamation
distincte.

**b) Le pharmacien oublie de pointer son départ.**
Aucun financement ne se déclenche. Proposition : **pointage de départ
automatique à l'heure de fin prévue au contrat + 2 h**, marqué comme automatique,
avec avis aux deux parties. Le quart est financé au montant du contrat.

**c) Le pharmacien n'a pas de carte de débit admissible.**
Proposition : **bloquer l'acceptation du quart** tant qu'une carte de débit
admissible n'est pas enregistrée, avec un message clair à l'inscription. C'est
le seul moyen de tenir la promesse « toujours instantané » sans deuxième
parcours de paiement.

---

## 5. Ce que ça change pour la pharmacie

Sans Interac, chaque quart passe par la carte. Sur un quart de 1 360 $ :

| | Avant (Interac) | Maintenant (carte + instantané) |
|---|---|---|
| La pharmacie paie | 1 399 $ | à recalculer par Robert (~1 455 $ avec le 1 %) |
| Le pharmacien reçoit | 1 360 $ | 1 360 $ |
| Délai pour le pharmacien | ~30 min | ~30 min |
| Geste du propriétaire | une connexion bancaire | **aucun** |

Douze quarts par mois font environ **17 000 $ par mois sur une seule carte**.
Les plafonds de crédit deviennent une contrainte réelle, pas théorique. À
surveiller dès les premières pharmacies multi-quarts.

En échange, tout le volet fraude Interac disparaît : plus de courriel
d'autodépôt à verrouiller, plus de refroidissement 72 h (qui n'est de toute
façon pas appliqué aujourd'hui), plus de message « envoyez 1 400 $ par virement »
qui ressemble trait pour trait à une fraude du président.

---

## 6. Ordre de construction proposé

1. **Phase 4** (Interac coupé) — petit, isolé, immédiat.
2. **Phase 1** (virement instantané) — c'est la promesse ; à faire tôt pour la
   tester avec de vrais montants.
3. **Phase 2** (pointage) — indépendant du paiement, testable seul.
4. **Phase 3** (avenant) — dépend de la Phase 2.

Chaque phase : une migration SQL numérotée, un commit séparé, un test réel avant
de passer à la suivante. Le Worker `c-direct-payments` ne s'auto-déployant pas,
chaque phase qui le touche exige `npx wrangler deploy` par Robert.
