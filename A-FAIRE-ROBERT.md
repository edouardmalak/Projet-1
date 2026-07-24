# What you need to do — plain-language guide

Everything below is a manual step that I (Cowork) can't fully do on my own. I've marked each one:
- 🤖 = **I can do this for you** (just ask) — your Supabase dashboard is logged in, so I can run the database steps.
- 🧑 = **only you can do this** (it needs a password, an API key, or your phone).

The website already works and won't break if you do none of this. These steps just *switch on* the newest features and get you launch-ready.

---

## ÉTAT ACTUEL — 2026-07-23 (mis à jour)

**Fait aujourd'hui (aucune action de votre part) :**

- Assistant IA (texte) construit + **déployé + branché** : Worker `c-direct-chat`
  en ligne, clé API en secret chiffré, site relié. Mascotte pharmacien sur les
  tableaux de bord + accueil du site. Anti-cache ajouté.
- `sql/21` (blocages/exclusions) **exécuté** — la fonction Blocages de l'admin est active.

**À vous — pour terminer / avant lancement :**

1. **💳 Créditer l'assistant IA** — au moins **5 $** à console.anthropic.com →
   Billing → *Buy credits*. Sans ça, l'assistant répond « crédit insuffisant ».
   C'est la SEULE chose qui bloque sa première vraie conversation.
2. **🔑 Rotationner le jeton Twilio** (maintenant payant = vraie facture si fuite) :
   Twilio console → régénérer l'Auth Token → mettre à jour le secret
   `TWILIO_AUTH_TOKEN` du Worker `c-direct-sms`. (Je vous guide.)
3. **🧹 Purger les données de test** — script prêt : `sql/22-purge-donnees-test.sql`
   (2 contrats CD-100012/100013). Puis supprimer les 2 comptes de test
   (`+pharmacien` / `+pharmacie`) dans Authentication → Users. NE PAS supprimer
   edouardmalak@gmail.com. (Je peux charger le script dans votre éditeur ; le clic
   « Run » reste à vous.)
4. **📧 DMARC** (courriels hors du spam) — Cloudflare → DNS → TXT `_dmarc` =
   `v=DMARC1; p=none; rua=mailto:edouardmalak@gmail.com`.
5. **🔓 Google sign-in** — encore désactivé : Supabase → Auth → Providers →
   activer Google + coller Client ID/Secret.

**Optionnel / plus tard :** SMS d'attribution (corriger le WEBHOOK_SECRET),
SMS de bienvenue à l'opt-in, taxes des autres pharmaciens (`sql/17`).

Détails assistant : `workers/c-direct-chat/README.md`. Garde-fous : l'assistant
ne lit qu'avec les droits de l'usager, et toute action (publier un quart, changer
les disponibilités) affiche une carte **Confirmer / Annuler**.

---

## NEW — Fix "Log in with Gmail" (5 minutes) 🧑

Google sign-in currently fails with *"provider is not enabled"* — this is a Supabase setting, not a website bug (the button and code are fine; it now shows a friendly message instead of a raw error page).

1. **Google Cloud Console** → APIs & Services → Credentials → your OAuth 2.0 Client (or create one, type "Web application"). Under **Authorized redirect URIs** add `https://fenlujjozanerbzyypjt.supabase.co/auth/v1/callback`; under **Authorized JavaScript origins** add `https://projet-1-1yi.pages.dev`. Copy the **Client ID** and **Client secret**.
2. **Supabase** → Authentication → **Providers → Google** → toggle **Enabled**, paste the Client ID + secret → **Save**.
3. **Supabase** → Authentication → **URL Configuration → Redirect URLs** → add `https://projet-1-1yi.pages.dev/acces?mode=suite` (and the `.html` version).

That's it — the "Continuer avec Google" button will work.

---

## PART 1 — Run 4 database files (5 minutes) 🤖

These are small text files of database instructions. They turn on: real distance math, the "N pharmacists available" hint, and the language + confirmed-contract email.

**The easy way:** just tell me "run the SQL files" and I'll do all three through your browser.

**If you'd rather do it yourself:**
1. Go to **supabase.com** → open your **c-direct** project → click **SQL Editor** (left menu).
2. For each file below: open it from the `sql/` folder, copy everything, paste into a new query, click **Run**.
   - `sql/13-distance-code-postal.sql`
   - `sql/14-fsa-compatibles.sql`
   - `sql/15-langue-et-confirmation.sql`
   - `sql/21-exclusions.sql`  ← **NEW** (the block/exclusion feature)
3. Each should say "Success". That's it.

**What they do:** #13 shows real driving distances/allowances on contracts. #14 powers the "X pharmacists compatible on {date}" line when you post a contract. #15 adds the French/English language choice and prepares the confirmed-contract email. **#21 turns on "Blocages"** in the admin console: separate a pharmacy and a pharmacist so they no longer see each other's postings/applications (mutual). Until #21 is run, the Blocages panel shows but saving says "Non activé".

---

## PART 2 — Turn on the confirmed-contract email + PDF (10 minutes) 🧑

This is the feature where, once a contract is agreed, both sides get an email ("Here is your confirmed contract") in their language with a PDF attached. It uses a service called **Resend** to send email. Only you can do this part (it involves an API key).

**Step A — Get a Resend account + key (if you don't already have one):**
1. Go to **resend.com** → sign up (free tier is plenty).
2. Left menu → **Domains** → add **c-direct.ca** and follow their instructions to add the DNS records (this proves you own the domain so email isn't marked spam). Wait until it shows **Verified**.
3. Left menu → **API Keys** → **Create API Key** → copy the key (starts with `re_...`). Keep it private.

**Step B — Give the key to your Worker:**
1. Go to **Cloudflare** → **Workers & Pages** → open **c-direct-sms**.
2. **Settings** → **Variables and Secrets** → **Add** → type **encrypted** secret.
3. Name: `RESEND_API_KEY` — Value: paste the `re_...` key → **Save**.
4. (Optional) Add another secret named `RESEND_FROM` with value `C-Direct <notifications@c-direct.ca>`.
5. It redeploys automatically. Done — the next accepted contract will email both parties with the PDF.

> Until you do Part 2, nothing breaks — the confirmed-contract email just stays off.

---

## PART 3 — Test that it works (15 minutes) 🧑

You need to be logged in as your test accounts (I can't type passwords). Gmail aliases all land in your inbox.

1. **Log in as the pharmacie** (`edouardmalak+pharmacie@gmail.com`) → post a contract at 130 $/h. Try 100 $/h → it should be refused (below the network floor).
2. **Log in as the pharmacien** (`edouardmalak+pharmacien@gmail.com`) → open the contract → **Postuler**.
3. **Back as the pharmacie** → **Accepter**. → Both accounts should get the confirmed-contract email + PDF (if Part 2 is done).
4. **SMS test:** in the admin console, click **"Envoyer un SMS test à mon numéro"** → a text should reach your phone (your Twilio number must be verified / have a little credit).

---

## PART 4 — Housekeeping before real launch 🧑 / 🤖

- 🤖 **Delete the test data** I created (contracts CD-100012 / CD-100013 and their invoices) so real users start clean. Just ask and I'll remove them.
- 🧑 **Rotate your Twilio Auth Token** (it may have been briefly visible during setup) — Twilio console → regenerate → update the Worker secret.
- 🧑 **Supabase login URLs:** Supabase → Authentication → URL Configuration → add `https://c-direct.ca/**` and `https://projet-1-1yi.pages.dev/**`.
- 🧑 The full pre-launch checklist (backups, 2FA, removing the dev wall) is in **`LAUNCH.md`** — do it the day you go live.

---

## Quick priority order
1. **Part 1** (I can do now) — unlocks the built features.
2. **Part 2** — only if you want the automatic confirmed-contract emails.
3. **Part 3** — test.
4. **Part 4** — when you're getting ready to launch for real.

Tell me **"run the SQL files"** and I'll knock out Part 1 for you right now.
