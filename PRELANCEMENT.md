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

- ⏳ **SMS d'attribution/lifecycle — CAUSE TROUVÉE (2026-07-23).** Ce n'était pas un
  « mismatch » : le secret **`WEBHOOK_SECRET` est tout simplement ABSENT** du Worker
  `c-direct-sms`. Diagnostic : `GET https://c-direct-sms.edouardmalak.workers.dev/diag`
  → `"webhook_secret_set": false`. Seuls 6 secrets ont été ajoutés (Twilio ×3,
  Supabase ×2, Resend) ; le 7e a été oublié. Résultat : `secretValide()` renvoie
  toujours faux → tous les webhooks Supabase reçoivent **401** → aucun SMS de cycle
  de vie ne part.
  **Correctif (Robert — c'est une valeur secrète) :**
  1. Supabase → Integrations → Webhooks → ouvrir un des 4 webhooks → section
     **HTTP Headers** → copier la valeur de l'en-tête `x-webhook-secret`.
     (Si l'en-tête est absent là aussi : générer une valeur aléatoire solide et la
     mettre AUX DEUX endroits — les 4 webhooks ET le Worker.)
  2. Cloudflare → Workers → `c-direct-sms` → Settings → Variables and secrets →
     **+ Add** → type **Secret** → nom `WEBHOOK_SECRET` → coller la valeur → Deploy.
  3. Revérifier `/diag` : doit afficher `"webhook_secret_set": true`.
- 🟡 SMS de bienvenue à l'opt-in (à construire ; touche le Worker live).
- 🟡 Taxes des autres pharmaciens — `sql/17` (colonnes TPS/TVQ/société au profil).
- 🟡 Retirer l'endpoint temporaire `/diag` du Worker `c-direct-chat` (nettoyage —
  Claude le fait une fois la 1re vraie conversation validée).
