# PRÉLANCEMENT — tout ce qu'il reste à faire

Liste unique et à jour. Mise à jour : 2026-07-23.
Légende : ✅ fait · ⏳ en cours · 🔲 à faire · 💤 en attente (décision de Robert)

---

## Déjà fait ✅

- ✅ Assistant IA déployé, crédité (5 $) et **fonctionnel** (diag `ok:true`).
- ✅ `sql/21` exécuté — fonction Blocages/exclusions active.
- ✅ Purge des 2 contrats de test Cowork (CD-100012 / CD-100013).
- ✅ Twilio passé au forfait payant (SMS vers n'importe quel numéro).

---

## PHASE 8 — 5 nouvelles fonctions (construites 2026-07-26) ⏳

Le code est en ligne. **Deux actions vous reviennent** pour tout activer :

- ✅ **`sql/23-phase8.sql` EXÉCUTÉ** (2026-07-26) — vérifié 7/7 :
  4 colonnes majoration · 6 colonnes fiche d'accueil · table `fils` ·
  index « un seul fil ouvert » · `messages.fil_id` · les 5 fonctions ·
  cron horaire `c-direct-hausses-auto` actif.
  Les fonctions 1, 2 et 3 sont donc **pleinement opérationnelles**.

- 🔲 **Google Agenda (optionnel)** — pour la synchro du calendrier :
  1. Google Cloud Console → APIs & Services → **Enable** l'API *Google Calendar*.
  2. Credentials → **Create OAuth client ID** → type *Web application*.
     - Authorized JavaScript origins : `https://c-direct.ca` **et**
       `https://projet-1-1yi.pages.dev`
     - (aucun redirect URI nécessaire : jeton côté navigateur)
  3. Copier le **Client ID** dans `supabase-config.js` →
     `window.CD_GOOGLE_CLIENT_ID = "…"` puis me dire « sync Google prêt ».
  4. Écran de consentement : tant qu'il est en *Testing*, ajouter les
     pharmaciens en *Test users* — ou le publier pour l'ouvrir à tous.
  Sans identifiant, le calendrier fonctionne normalement, le bouton reste inactif.

**Ce qui a été construit :**

| # | Fonction | Où |
|---|---|---|
| 1 | Majoration auto du tarif (paliers + plafond) | `profil.html` (pharmacie) · `sql/23` |
| 2 | Fiche « ce que vous devez savoir » + PDF | `profil.html` · `fiche-accueil.html` · lien dans `mes-mandats.html` |
| 3 | Messagerie : un seul fil par contrepartie + clôture mutuelle | `messages.html` · `sql/23` |
| 4 | Calendrier plein écran, glisser-sélectionner, sync Google | `disponibilites.html` |
| 5 | Sortie explicite sur `contre-offre.html` · page d'attente auto | `contre-offre.html` · `attente.html` |

---

## À finir avant le lancement 🔲

1. 🔲 **Supprimer les 2 comptes de test** — Supabase → Authentication → Users :
   `edouardmalak+pharmacien@gmail.com` et `edouardmalak+pharmacie@gmail.com`.
   **Garder** `edouardmalak@gmail.com` (admin).

2. ✅ **Jeton Twilio rotationné** (2026-07-23) — token secondaire créé → collé dans
   le secret `TWILIO_AUTH_TOKEN` du Worker → promu primaire (l'ancien, possiblement
   exposé, est supprimé). À confirmer : test SMS end-to-end (le token pasté = valide).

3. 💤 **Purger les ~24 contrats de test restants** (CD-100014 → CD-100037) —
   EN ATTENTE : Robert décide si on nettoie tout le tableau avant le lancement.
   Quand décidé, Claude prépare le script (même méthode que `sql/22`).

4. ✅ **DMARC ajouté** (2026-07-23) — TXT `_dmarc` dans Cloudflare DNS.

5. 🔲 **Activer Google sign-in** — Supabase → Auth → Providers → Google +
   Client ID/Secret + redirect URLs.

6. 🔲 **Retirer le mur Cloudflare Access** qui protège `c-direct.ca` (le jour J).

7. 🔲 **Revue légale Loi 25 / CASL** signée (Martin) avant d'inviter des usagers.

---

## Optionnel / après lancement 🟡

- ✅ **SMS d'attribution/lifecycle — RÉPARÉ (2026-07-23).** Ce n'était pas un
  « mismatch » : le secret `WEBHOOK_SECRET` était **absent** du Worker `c-direct-sms`
  (seuls 6 des 7 secrets avaient été remis). `secretValide()` renvoyait donc toujours
  faux → les 4 webhooks Supabase recevaient **401** → aucun SMS de cycle de vie.
  Correctif appliqué : valeur `x-webhook-secret` (déjà présente côté Supabase) copiée
  dans un nouveau secret `WEBHOOK_SECRET` du Worker. `/diag` confirme maintenant
  `resend·supabase·twilio·webhook_secret_set = tous true`.
  **Reste à valider par un vrai test** (poster un contrat → accepter → vérifier que
  le texto arrive), maintenant que Twilio est payant.
- 🟡 SMS de bienvenue à l'opt-in (à construire ; touche le Worker live).
- 🟡 Taxes des autres pharmaciens — `sql/17` (colonnes TPS/TVQ/société au profil).
- 🟡 Retirer l'endpoint temporaire `/diag` du Worker `c-direct-chat` (nettoyage —
  Claude le fait une fois la 1re vraie conversation validée).
