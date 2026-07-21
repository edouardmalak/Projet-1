# C-Direct — À faire plus tard

État au moment de la pause. Le site fonctionne. Rien d'urgent ne bloque.

## ✅ Fait (rien à faire)
- Courriel « contrat confirmé » + PDF (format MANDAT/facture) aux 2 parties, dans leur langue — **livraison confirmée** (statut Resend « delivered »).
- Numéros de taxes (TPS/TVQ/société) affichés + taxes calculées automatiquement (repris de fiche.js par courriel).
- « Facturé à » et tous les champs remplis dynamiquement depuis les profils.
- Anti-spam de base ajouté (reply-to + version texte).
- Accueil : plus d'intro ni de fenêtre de bienvenue (accès direct).
- SQL 13, 14, 15 exécutés.

## 🔴 À faire (par ordre d'importance)

1. **Sortir les courriels du spam (2 gestes) :**
   - Dans Gmail : ouvrir le courriel « Contrat confirmé » (probablement dans **Spam**) → **Non-spam**.
   - Ajouter l'enregistrement **DMARC** dans Cloudflare → DNS → Add record :
     - Type `TXT` · Nom `_dmarc` · Contenu `v=DMARC1; p=none; rua=mailto:edouardmalak@gmail.com`
   - (DKIM + SPF déjà faits via la vérification du domaine Resend.)

2. **Taxes des AUTRES pharmaciens :** seul edouardmalak@gmail.com a ses numéros dans le Worker (REGISTRE_FISCAL, dans `workers/c-direct-sms/src/index.js`). Pour que d'autres pharmaciens aient leurs taxes sur leurs mandats : soit exécuter **`sql/17-facturation-pharmacien.sql`** (ajoute les champs TPS/TVQ/société au profil, à remplir dans la page Profil), soit les ajouter au REGISTRE_FISCAL.

3. **SMS d'attribution / lifecycle (optionnel) :** ne fonctionnent pas — le **WEBHOOK_SECRET** des Database Webhooks Supabase ne correspond pas à celui du Worker. Le courriel de confirmation, lui, fonctionne (il passe par le site → Worker, sans ce secret). Pour activer les SMS : re-régler le WEBHOOK_SECRET (valeur dans `workers/c-direct-sms/README.md`) dans les webhooks Supabase pour qu'il corresponde.

4. **Nettoyer les données de test avant le lancement :** contrats CD-100012 / CD-100013, leurs factures, et le profil pharmacie de test (j'y ai mis des données fictives « Pharmacie du Village » — à remplacer par vos vraies données ou à purger). Script de purge dans `LAUNCH.md`.

5. **Rotation du jeton Twilio** (sécurité — possiblement exposé pendant la config).

## 🟡 Optionnel / plus tard
- Mettre le même PDF MANDAT sur la **facture finale** (à la complétion), en plus de la confirmation.
- Reste Phase 6 : SMS de bienvenue à l'opt-in, passe de contenu des pages publiques.
- Extras Phase 2.4 : favoris, onglets (Disponibles/Confirmés), stat de réactivité.
- Checklist de lancement complète : `LAUNCH.md`.

## Points de restauration (git tags — aucun supprimé)
`restore-phase-1` … `restore-phase-6-complete`, `restore-confirmation-pdf`. Pour revenir en arrière : dites-moi lequel.
