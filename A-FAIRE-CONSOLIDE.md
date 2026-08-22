# C-Direct — Everything left to do (consolidated, updated 2026-08-06)

This replaces scattered notes across `PRELANCEMENT.md`, `A-FAIRE-ROBERT.md`, `A-FAIRE-PLUS-TARD.md`, `LAUNCH.md`, and `PLAN-APP-MOBILE.md` with one current list. Those files still exist for history, but **this is the one to check going forward.** I verified the items marked "confirmed live" below by actually checking (admin console, cookies) rather than trusting the old docs, since several of them had gone stale.

Legend: 🧑 = only you can do this (password, account, real money, a decision). 🤖 = I can do this once you say go.

---

## 0. À exécuter maintenant — 2 migrations SQL (audit 2026-08-09)

Deux correctifs de sécurité/logique poussés le 2026-08-09 attendent d'être **exécutés en base** (Supabase → SQL Editor). Le code est déjà en prod ; il faut lancer le SQL pour que la base suive.

1. 🧑 **`sql/62-restaure-gardes-instant-booking.sql`** — restaure les gardes de l'acceptation automatique (Instant Booking). La version live de `accepter_candidature_auto()` avait dérivé et n'avait plus AUCUNE garde (elle acceptait toute candidature qu'on lui passait) et retournait `void` au lieu de `boolean`. Le Worker a déjà reçu une défense en profondeur (il revérifie favori/exclusions avant d'appeler), mais la base doit être recorrigée. ✅ **DONE — exécuté en Supabase 2026-08-09.**
2. 🧑 **`sql/63-durcissement-acl-fonctions.sql`** — ferme l'accès **anonyme** à des fonctions restées publiques. Vérifié en direct sans session : `get_stats_pharmacien` et `get_note_profil` répondaient à un client anonyme, et le mutateur `appliquer_indemnites` était exposé. Après exécution, revérifier que le site connecté marche (profil, évaluations, mandats). ✅ **DONE — exécuté en Supabase 2026-08-09.**

3. 🧑 **`sql/64-admin-reactiver-compte.sql`** — ajoute les boutons admin Réactiver/Désactiver un compte (la désactivation libre-service n'avait aucun retour arrière) et réactive au passage le compte de test `edouardmalak+pharmacien@gmail.com`. ✅ **DONE — exécuté en Supabase 2026-08-09.**
4. 🧑 **`sql/65-avatars-storage.sql`** — crée le bucket de stockage `avatars` pour la photo de profil **facultative** du pharmacien. Sans lui, le reste du profil s'enregistre quand même ; seule la photo affiche « Stockage non activé ». ✅ **DONE — exécuté en Supabase 2026-08-09.**

(Copier-coller le contenu de chaque fichier dans Supabase → SQL Editor → Run. Tous sont idempotents. Ordre conseillé : 62, 63, 64, 65.)

---

## 1. Right now — Stripe live mode (full runbook, updated 2026-08-15)

Robert confirmed 2026-08-15 that Stripe verification is done. Follow these steps **in order**. Nothing on the site needs to change except ONE line (step 3) — everything else is dashboard clicks and two secrets.

> ✅ **ÉTAT 2026-08-15 — les deux clés sont en mode live.** Step 3 done (site sends `pk_live_…`, commit `9cbca86`); step 2 done (Robert pasted `sk_live_…` into the Cloudflare secret). `/health` re-checked after the save: `stripe_key_configured:true` **and** `supabase_configured:true`, so no other secret was overwritten.
> **Live key CONFIRMED working 2026-08-15:** the Paiements tab returned *"No such customer: 'cus_UzTijgEyhLkHVN'"* — Stripe answered the Worker, which only happens if the live key authenticated. A wrong key gives an auth error instead.
>
> ✅ **TEST B PASSED — 2026-08-15.** Both follow-ups done: `sql/80` executed in Supabase, and the payments Worker redeployed with `cdirect.quebec` added to its CORS allowlist (version `c56a8d1f`). Verified by reading `stripe_comptes` directly: the **pharmacie** row has `stripe_customer_id` AND `stripe_payment_method_id` populated — a real card is saved in live mode and C-Direct knows which one, so the per-shift clone has what it needs.
>
> ✅ **IDENTITY DOCUMENT ACCEPTED — 2026-08-17.** https://dashboard.stripe.com/connect/accounts/overview now shows **"Thanks for providing a valid identity document."** where the yellow "We need a valid identity document for EDOUARD ABDEL MALAK" banner used to be. That half of step 5 is genuinely done.
>
> ⛔ **BUT STEP 5 IS NOT CLEARED — a second, separate gate remains: the Connect PLATFORM PROFILE questionnaire.** Proven live 2026-08-17: clicking « Configurer mes paiements » in Paramètres → Paiements still returns *"You must complete your platform profile to use Connect and create live connected accounts. Visit your dashboard at https://dashboard.stripe.com/connect/accounts/overview to answer the questionnaire."* So the identity document and the platform profile are two different requirements, and only the first is satisfied.
>
> **Correction of an earlier note in this file:** on 2026-08-17 Claude first recorded the "Onboarding incomplete / View onboarding" text on the Platform profile page as *stale*, reasoning that **View onboarding** presents no form and bounces back to Connect overview. That inference was wrong — the bounce is a broken link, not evidence of completeness. The page means exactly what it says.
>
> **What is actually missing.** Settings → Connect → **Platform profile** says under *Funds flow*: "you must acknowledge the **negative balance liability** AND refunds and chargebacks waiver below", but only **Refunds and chargebacks liability acknowledgement** is listed (Completed August 17, 2026), alongside *Ongoing seller compliance acknowledgement* (same date). There is no negative-balance-liability row and no control to add one. Hence "Onboarding incomplete — Elections will be shown below once completed."
>
> **ROOT CAUSE — a circular lock in Stripe's own setup guide.** Maximising the Setup guide widget (it hides most of itself when collapsed) reveals the full checklist: **Set up Connect** ✅ (business model / test connected account / integration guide) · **Verify your account** (Verify your email ✅, **Activate payments** ⭕ NOT ticked, Create your Stripe profile 🔒) · **Go live** 🔒 (Verify your identity 🔒, **Confirm your integration choices**, Get your API keys 🔒) · **Set up tax collection** 🔒.
>
> *Confirm your integration choices* — under the locked **Go live** section — is the task that matches the Connected-accounts card wording "Finish **confirming your integration** before creating your first live account", i.e. it IS the questionnaire the API error demands. Hovering the locked section returns the tooltip **"Activate products to unlock this task."** Unlocking it requires ticking **Activate payments** — and that link lands on `/account/activated` → "Thanks for activating your account! You can now make live transactions", because the account is *already* activated. So the one task that would clear the Connect gate is locked behind a step Stripe simultaneously treats as incomplete (in the guide) and complete (on the account). Robert cannot break this from the UI.
>
> **Everything on Robert's side is complete — verified 2026-08-17, nothing is missing and nothing in C-Direct's code is at fault:** Settings → Business → Business details has business website C-DIRECT.CA, address, Tax ID, Product description, Phone, Industry, public business name, support phone +1 (514) 569-0139, statement descriptor `C DIRECT`; EDOUARD ABDEL MALAK on file as Account representative + Owner with ID document, DOB, job title and phone, plus a second person as Director. `/settings/account-status` redirects to Home, meaning Stripe lists **no outstanding account requirements**. `/settings/connect/platform-setup` shows all five integration selections correctly (direct charges; Stripe collects fees from sellers; Stripe responsible for losses; dashboard none; Stripe-hosted onboarding) but is the *recommendation* tool, not the binding profile. Other dead ends tried: Platform profile → *View onboarding* bounces to `/connect` with no form; Settings → Connect exposes only the two read-only pages; Connect overview and Home carry no CTA. Developers → Errors shows **5 × `POST /v1/accounts` failures in 24 h** — Robert's attempts.
>
> ✅ **RESOLVED 2026-08-17 — the gate was "Activate products", and the missing answer was the payments integration choice.** Stripe's Assistant escalated toward a support agent, and in that flow the dashboard finally surfaced **"How do you want to accept payments?"**. Selecting **Custom payment flow** (individual UI components / Elements — NOT payment links, NOT the pre-built checkout form, because C-Direct creates the T-24h authorization server-side with nobody at a keyboard) and saving immediately flipped the Connected accounts page from *"Connect setup almost complete"* to **"Connect setup complete — Finish building your application and onboard your first users"**, with the **Create** button enabled. Verified in the live dashboard.
>
> Deliberately NOT enabled while there: *Send invoices* (Stripe Invoicing would bill in C-Direct's name and undercut the "the locum invoices the pharmacy, C-Direct only transmits" positioning), *Collect tax* (Stripe Tax is a separate paid decision), *Verify customer identities* (Connect onboarding already handles locum KYC). Setup-guide goals left at **Accept online payments + Build a platform** only.
>
> The guide's remaining *"Create a non-recurring product"* task is a generic checklist item and is **not** a gate — C-Direct needs no Stripe Product, because shift amounts are computed per shift `(locum_rate + 39 + 0.30) / (1 - 0.029)` and the $39 is taken as `application_fee_amount` on the direct charge, not sold as a catalogue item. Do not create one.
>
> ✅ **LIVE CONNECT ONBOARDING DONE — verified in Supabase 2026-08-17 (webhook timestamp 2026-08-18T03:32Z).** Robert completed the Stripe-hosted onboarding from « Configurer mes paiements ». `stripe_comptes` now shows: **pharmacien** (edouardmalak+pharmacien@gmail.com) → `stripe_account_id` = `acct_1U5dBvDn37SeUr1A`, `charges_enabled: true`, `payouts_enabled: true`, requirements all empty, `disabled_reason: null`; **pharmacie** (edouardmalak+pharmacie@gmail.com) → `cus_V4tWbFpKNE7Cgl` + `pm_1U4kByReBKCY8Yl1iYCqSbEm` (card on file since 2026-08-15). Both sides of the T-24h hold are in place — **nothing blocks step 6's Test C and the mirror test anymore.**
>
> Note for launch (not a blocker): Robert found the corporate onboarding long. Locum onboarding is the shorter *individual* flow, and the plan already defers it to first shift acceptance rather than signup — watch drop-off there after launch.

**Never paste `sk_live_...` or `whsec_...` into chat, email, or any file in this folder — the repo is publicly downloadable.** The publishable key `pk_live_...` is the only key that is safe to share (it's public by design).

1. 🧑 **Double-check verification really finished (2 min).** Open https://dashboard.stripe.com — if there is NO orange/red banner asking for business info or bank details on the home page, you're good. Also check Balances → Payouts shows your bank account. (The "Thank you for providing additional information" email means Stripe received your info; the absence of a banner means they accepted it.)
2. ✅ **DONE 2026-08-15. Put the live secret key in the Worker (5 min).**
   a. Stripe → click **Developers** (bottom left) → **API keys**. Make sure the page does NOT say "Test mode" / sandbox at the top — you want the real account "9269 0031 Québec Inc".
   b. Copy the **Publishable key** (`pk_live_...`) — paste this one to Claude in chat (safe), it's needed for step 3. ✅ **DONE 2026-08-15.**
   c. Click **Reveal live key** on the **Secret key** (`sk_live_...`) and copy it. Stripe may only show it once — keep the tab open until step 2d is done.
   d. New browser tab: Cloudflare dashboard → **Workers & Pages** → **c-direct-payments** → **Settings** → **Variables and Secrets** → `STRIPE_SECRET_KEY` → **Edit** → paste the `sk_live_...` value → **Save/Deploy**. Saving a secret redeploys the Worker by itself — no terminal needed (the current code is already deployed; `/health` verified OK 2026-08-15).
   e. Verify: open https://c-direct-payments.edouardmalak.workers.dev/health — it must still show `"stripe_key_configured":true`. (This only proves a key is present, not that it's the live one — the real proof is Test B in step 6 succeeding.)
3. ✅ **DONE 2026-08-15 (commit `9cbca86`).** Publishable key swapped in `parametres.html` line 387: `pk_test_51Tz4YU…` (sandbox account) → `pk_live_51Tz4YO…`. The `51Tz4YO` portion matches `acct_1Tz4YOReBKCY8Yl1` = "9269 0031 Québec Inc", so the key is confirmed to belong to the real live account. `parametres.html` is the only page that loads Stripe.js and the only file that held a key — nothing else touched. **Undo:** `cd "Projet 1" && git revert 9cbca86 && git push`
4. ✅ **DONE — verified by Claude 2026-08-15, nothing left to do here.** Webhook IS in live mode: destination `we_1U3gGYReBKCY8Yl1MLRcYK30`, name `c-direct-payments-worker`, URL `.../stripe/webhook`, scope **Connected accounts**, 9 events, signing secret present, API version 2026-06-24.dahlia. It is **enabled** — the `...` menu offers "Disable", which it would not if it were already off. Deliveries: **0 total, 0 failed**, so the orange **"Requires setup"** badge simply means Stripe has never seen a successful delivery yet (no live connected account and no live PaymentIntent have existed). Expect it to clear on the first real event — already tracked as L-2. Only remaining unknown: whether the Worker's `STRIPE_WEBHOOK_SECRET` matches this destination's current secret; it was set from this very destination on 2026-08-12 and has not been rolled since, so it should. L-2 proves it for real. **Do NOT roll the secret** — that would break the match and require re-pasting it into Cloudflare.
   <details><summary>Original manual instructions, no longer needed</summary>
   Confirm it's in live mode: Stripe → **Developers** → **Webhooks / Event destinations**, with test/sandbox mode OFF.
   - If it's listed there in live mode: click it, **Reveal signing secret** (`whsec_...`), and make sure the Worker has THAT value: Cloudflare → c-direct-payments → Settings → Variables and Secrets → `STRIPE_WEBHOOK_SECRET` → Edit → paste → Save.
   - If it's NOT listed in live mode: **Add destination** → tick **"Listen to events on Connected accounts"** → events: `account.updated` + all `payment_intent.*` (same 9 as before) → endpoint URL `https://c-direct-payments.edouardmalak.workers.dev/stripe/webhook` → create → copy the `whsec_...` signing secret → paste into the same Cloudflare secret as above.
   - Either way the 15-min cron keeps covering everything if a webhook is missed, so this can't break payments — it's belt and suspenders.
   </details>
5. ✅ **DONE 2026-08-17 — both halves cleared: identity document accepted, and the Connect gate lifted by choosing "Custom payment flow" as the payments integration (see the ÉTAT block above). "Connect setup complete" confirmed in the live dashboard.** Attempting live Connect onboarding previously returned: *"You must complete your platform profile to use Connect and create live connected accounts."* That message is misleading — the real requirement, visible at https://dashboard.stripe.com/connect/accounts/overview, is a yellow banner: **"We need a valid identity document for EDOUARD ABDEL MALAK to use Connect and create live connected accounts."** Clicking **Get started** opens Stripe Identity: photo of a government ID (driver's licence or passport) **plus a selfie**, with biometric consent. Best done on a phone — Stripe offers "continue on your mobile device". Deferred 2026-08-15: Robert was at work without ID on him. **Nothing else in the payment rail can be tested until this passes** — no connected account means no T-24h authorization can be created, which blocks step 6's Tests C and the mirror test. This is a one-time platform-level check on the business owner; separate from the verification already passed for accepting card payments, and separate again from what each pharmacist does for their own account.
6. 🧑 **Small-amount tests with your real card, in this order:**
   - **Test A — $1 sanity check (no site involved, 3 min).** Stripe dashboard (live) → **Payments** → **Create payment** → CA$1.00, enter your card manually → confirm it succeeds → open the payment → **Refund** it. Proves the live account can charge cards. Costs only the non-refunded 30¢ fixed fee.
   - **Test B — save a card on the site ($0).** Log in on c-direct.ca as the pharmacy test account → Paramètres → onglet Paiements → enter your real card. Proves `pk_live` (site) + `sk_live` (Worker) + SetupIntent work together in live mode. No charge — saving a card costs nothing.
   - **Test C — full circuit, small amount (~$41).** Onboard yourself as a locum from **Paramètres → onglet Paiements → « Recevoir mes paiements » → bouton « Configurer mes paiements »** (`parametres.html`, button `btn-onboarding-stripe` → Worker `/pharmacien/onboarding-start`). Corrected 2026-08-17: earlier notes said `profil.html`, but that page contains no Stripe code — the onboarding button lives in `parametres.html` and the Paiements tab only appears once you are logged in as a pharmacien. Live Express onboarding — real SIN and bank, it's your own. Create a contract with 1 hour at the minimum rate so the total is tiny (the $39 fee is baked into the price, so the smallest possible hold is ≈ $41). Let the T-24h authorization fire, approve the timesheet, and deliberately DON'T confirm receipt — the deadline capture fires and real money moves: Stripe fee ~$1.50 leaves, ~$39 comes back to C-Direct as application fee, ~$1 lands in your locum bank. You're all three parties, so the net cost is only the Stripe fee. Then do the mirror test on a second contract: confirm *reçu, montant exact* → the hold is CANCELLED at $0 charged.
   - **After the first live event: check the webhook destination's Event deliveries shows 200** (existing L-2 item).
7. 🧑 **Every pharmacist redoes Stripe Connect onboarding for real.** Test-mode connected accounts don't carry over — live mode is a completely separate space. Each pharmacien goes through onboarding again from `profil.html` once live keys are in.
8. 🧑 **Every pharmacy re-enters a real card.** Same reason — test cards don't exist in live mode.

Later, optional (decided when Instant Payouts become a promise, not before): Stripe → Settings → Connect → Payouts → "Allow debit cards?" → Yes — in Canada instant payouts only work to a debit card, and this switch is dashboard-only.

---

## 2. Confirmed still blocking real users (verified today, not guessed)

- 🧑 **The Cloudflare Access wall is still up.** I checked directly — the browser session reaching c-direct.ca right now is carrying a `CF_Authorization` cookie, meaning Access is still gating the site and I'm only getting through because of an existing session. Nothing about this needs code. When you're ready to actually launch: Cloudflare → Zero Trust → Access → Applications → remove the C-Direct application. **This is the actual "go public" switch — do it last, after everything else below is settled.**
- 🧑 **Test accounts need cleaning up — there are 4, not the 2 the old docs mention.** I checked the admin console just now. Current accounts:
  - `edouardmalak+pharmacien4@gmail.com` — name on file: "je sais rien"
  - `edouardmalak+pharmacie1@gmail.com` — name on file: "La prénom pharmacie"
  - `edouardmalak+pharmacie@gmail.com` — name on file: "Pharmacie tring"
  - `edouardmalak+pharmacien@gmail.com` — name on file: "Edouard Malak" (Boucherville)
  
  Keep `edouardmalak@gmail.com` (admin) — that's the only real one. Delete the other four in Supabase → Authentication → Users when you're ready (I can prep the SQL cleanup for their contracts/candidatures/invoices first if you want — ask and I'll do it, the delete-click itself is yours).
- 🧑💤 **82 contracts currently exist in the system** (GMV $64,958.64 per the admin dashboard) — a mix of real testing and leftover test data from earlier sessions (the old CD-100012–100037 range was mentioned before). Worth a look through the Contrats tab before opening to real users, so nobody's first experience is seeing fake history. Your call on timing — say the word and I'll help identify what's test vs. real.
- 🧑 **Legal review (Loi 25 / CASL) signed off by Martin** — no record this happened yet. Needed before real users are invited.
- 🧑 **When approving a pharmacy, check the `Bannière` field is filled — refuse or chase if it's blank.** Standing manual check, decided 2026-08-16 (Robert chose the admin-approval gate over making the field required in code). Why it matters: the banner is what tells a locum **who he'd be working for** — the contract card is built to read "Jean Coutu · Boucherville" and silently degrades to the city alone when it's empty, which is the state of every pharmacy in the database today. No code involved: the field already exists (`profiles.banniere`, editable in `profil.html`), and `sql/25-verification-queue.sql` already counts it in the profile-completeness score shown in the admin console, so a blank banner is visible at approval time. Existing pharmacies need chasing separately — they were approved before this rule existed.

---

## 2bis. Trous du rail de paiement trouvés le 2026-08-15 (rapport C3 → `ETAT-RAIL-PAIEMENT.md`)

Trois écarts entre l'architecture prévue et ce qui tourne réellement. Aucun ne bloque la vérification d'identité Stripe ni les tests d'argent réel — mais le premier doit être réglé **avant d'ouvrir à de vraies pharmacies**.

- [x] 🤖 **P1 — Le refroidissement 72 h sur le courriel Interac — CORRIGÉ ET EXÉCUTÉ 2026-08-22 (`sql/96`).** VÉRIFIÉ en production : `lit_encore_la_table_morte = false`, `lit_la_bonne_colonne = true`. Confirmé exactement comme décrit : la porte j de `evaluer_quart_auto()` lisait `verification_interac`, table que plus rien n'écrit depuis sql/75 — elle ne se déclenchait donc jamais et laissait passer tous les quarts. `sql/96` repointe la porte vers `profiles.courriel_interac_cooldown_jusqua`, écrit par `confirmer_courriel_interac()` (sql/47) à `now() + 72 heures` sur un CHANGEMENT de courriel. C'est le correctif que le commentaire de sql/75 prescrivait lui-même. La fonction fait 226 lignes et a été remplacée en entier, mais le diff ne porte QUE sur la condition de la porte j — les 222 autres lignes sont identiques au caractère près, vérifié par diff avant écriture. Corrigé pendant qu'Interac est ÉTEINT (`interac_actif = false`), donc aucun risque de casser un flux en production. `verification_interac` n'est plus lue par personne : elle pourra être supprimée dans une passe ultérieure.
- [ ] 🤖 **P2 — Le palier « 16 h le jour ouvrable suivant » n'existe pas.** Les pharmacies ayant un comptable sont censées avoir cette échéance plus longue ; en réalité **tout le monde est sur le délai standard de 3 h** (`workers/c-direct-payments/src/index.js` le dit explicitement en commentaire). Conséquence concrète : un quart du dimanche ne peut pas être payé par un comptable qui travaille en semaine → la garantie sera capturée alors que la pharmacie n'a rien fait de mal. Sans impact tant que c'est Robert qui teste ; à régler avant d'accueillir des groupes de pharmacies.
- [ ] 💤 **P3 — Une seule carte par pharmacie.** L'échelle de relance prévoit un palier « essayer la 2e carte » qui n'a aucune 2e carte à essayer. Déjà listé en section 6 comme différé volontaire — rappelé ici parce que le rapport C3 l'a reconfirmé en lisant le code.

---

## 3. Built, just needs a switch flipped (all optional until you do)

- 🧑 **Google Calendar sync** (`disponibilites.html`) — code is done and push-only as of today, but `window.CD_GOOGLE_CLIENT_ID` in `supabase-config.js` is still blank. Steps (unchanged from before):
  1. Google Cloud Console → APIs & Services → Enable the **Google Calendar API**.
  2. Credentials → Create OAuth client ID → type **Web application**. Authorized JavaScript origins: `https://c-direct.ca` and `https://projet-1-1yi.pages.dev`. No redirect URI needed.
  3. Copy the Client ID, tell me, and I'll drop it into `supabase-config.js` and push.
  4. While the consent screen is in "Testing" status, add pharmaciens as Test users, or publish it to open it to everyone.
- 🧑 **Apple Sign-In** (new today) — the button exists on the login page and is fully wired, gated behind `window.CD_APPLE_ENABLED` in `supabase-config.js` (currently `false`) so clicking it shows a friendly local message instead of a raw Supabase error page. Two steps once you're ready: (1) Supabase → Authentication → Providers → Apple → toggle on, paste your Apple Developer Services ID / Team ID / Key (same shape of setup as Google was); (2) tell me it's done and I'll flip `CD_APPLE_ENABLED` to `true` and push.
- 🧑 **Taxes for pharmacists other than you** — right now only `edouardmalak@gmail.com` has GST/QST numbers wired into the invoice Worker. Run `sql/17-facturation-pharmacien.sql` in Supabase to add TPS/TVQ/société fields to every pharmacist's profile (they'd fill them in themselves).
- 🧑 **Push notifications** (new today) — Paramètres → Notifications is fully built (code-complete, live), but needs your VAPID keys before it can actually send anything; until then it shows a friendly "coming soon" message instead of a real notification. Steps, all in `workers/c-direct-sms/README.md` § 5:
  1. From your terminal: `cd workers/c-direct-sms && node generer-vapid.js` — prints two values. The first (public key) isn't secret; tell it to me and I'll drop it into `supabase-config.js` and push. The second (private key) is secret — don't share it with me, paste it straight into the next step.
  2. `npx wrangler secret put VAPID_PUBLIC_KEY` (paste the public value again) and `npx wrangler secret put VAPID_PRIVATE_KEY` (paste the private value) — no redeploy needed after, this Worker auto-deploys from git push and the code is already live waiting on these two secrets.
  3. Once both are set: activate notifications on your own phone/computer from Paramètres, then test with the `curl` command in the README § 5 (needs your `profil_id` from the `profiles` table and the `WEBHOOK_SECRET`). A real notification should arrive within seconds.
  I wrote the encryption code by hand following the Web Push standard (RFC 8291/8292) since I never handle the private key myself — it's never been tested against a real device, so step 3 is the one real verification this needs before you count on it.

---

## 4. Mobile app track (Phase 2 of `PLAN-APP-MOBILE.md`)

Site + payments are essentially done, so this can start whenever you're ready:

- 🧑 **Apple Developer Program** — $99 USD/year, apple.com/developer. Identity verification can take a few days, worth starting early even before the app itself begins.
- 🧑 **Google Play Developer** — $25 USD one-time, play.google.com/console.
- Deep-link verification files are already live (done 2026-08-04) — nothing to do there until the real app exists, at which point the placeholder Team ID / package name / cert fingerprint need to be swapped for real ones.

---

## 5. Housekeeping (not blocking, cheap to knock out)

- 🧑 **Admin 2FA** — moved to the launch checklist as **L-4** (Robert's call 2026-08-15: do it at the end, just before launch). Full step-by-step is there.
- 🧑 **Supabase auth emails** — password reset / signup confirmation still use Supabase's built-in email sender, which is rate-limited. Worth wiring a custom SMTP (you already have a working Resend account/domain from the confirmed-contract emails) before real signup volume hits.
- 🧑 **Supabase backups** — confirm daily backups are actually turned on (Project → Database → Backups) and note the retention window.
- 🧑 **Twilio low-balance alert** — set one up so broadcast SMS never silently fail on an empty balance.
- 🤖/🧑 **`espace-pharmacien.html` — is it safe to delete?** Flagged back on 2026-07-30: this page has no Supabase includes and nothing links to it (`contrats.html` is the real pharmacien landing page). Still sitting in the repo unused. Just needs a yes/no from you.
- 🤖 **Remove the temporary `/diag` endpoint** on the `c-direct-chat` Worker — cleanup only, low priority.
- 💤 **Welcome SMS on opt-in** — spec'd but never built (deliberately — needs a new profiles-UPDATE webhook + Worker handler on the live SMS Worker, hasn't felt worth the risk untested). Still just an idea, not started.

---

## 6. Explicitly deferred (decided already, not forgotten)

These came up during the payments build and were consciously left out rather than missed:

- 🤖 **Dead per-page `:root` colour blocks — clean up AFTER launch, but BEFORE any desktop restyling.** 31 pages declare their own colour variables in their inline `<style>`, then load `design.css`, which redeclares the same names in its own `:root`. Same specificity, later in the cascade — so `design.css` wins and the page's own block does nothing. **Editing a page's colour variables today has no visible effect**, which reads as "my change didn't save" rather than as a cascade problem. Verified 2026-08-16: `--ligne` and `--vert` are shadowed on all 31 pages, `--rouge` on 26, `--jaune` on 25, and `--fond`, `--ligne2`, `--panneau`, `--panneau2`, `--sourd`, `--texte`, `--vert-vif` on 24 each (`--menthe` on 7). Most pages carry **11 dead declarations**, not four. **Ordering matters:** this has to be done before desktop restyling starts, or whoever does that work will edit a page's colours, see nothing change, and be debugging a ghost. Background: `AUDIT.md` §3 (the three-layer cascade, `design.css` loaded after each page's inline `<style>`) and §12 item 3 (`--jaune` already contradicted between `design.css` and the pages). Not urgent on its own — nothing is visually broken today, the values simply come from `design.css`.
- The multi-card backup rung in the payment retry ladder (only one card per pharmacy today).
- The `account.updated` Stripe webhook (current code checks account status live instead — works, just costs one extra API call per cycle).
- Twilio inbound webhook for in-app STOP/ARRET sync (optional — the carrier already handles opt-out regardless; Twilio's US-only emergency-address form blocked this earlier).

---

## Already done — for context, not action

Confirmed via memory + live checks, no action needed: DMARC, Twilio token rotation, Twilio on a paid plan, Google sign-in (working live since 2026-07-26), the T-24h payment authorization/retry/capture cycle (fully automatic, confirmed via cron), the Cloudflare Workers Paid upgrade, mobile deep-link files, and the Stripe fee/liability sign-off (you gave informed consent on 2026-08-04 — Express accounts mean C-Direct absorbs Stripe's processing fee and chargeback risk, which is priced into the $39 fee).

## Open items — updated 2026-08-09
### Cowork (UI / site)
- [ ] 1. Welcome greeting next to the name, immediately after the C-Direct
       wordmark. Both the pharmacy site and the locum site, landing page and
       dashboard. Logged out: "Bienvenue"/"Welcome" alone. Logged in: with the
       first name. Must use the existing i18n mechanism — no hardcoded strings.
       STATUS: specified, not confirmed applied. Verify before building.
- [ ] 4. "Resend confirmation email" button on the login page. Needed because a
       duplicate unconfirmed user in Supabase fails silently — the user gets no
       email and no error.
- [ ] 5. This update itself.
- [ ] 6+. Bugs from the pre-launch test pass. To come.
### Claude Code (backend — NOT Cowork)
- [ ] C1. RLS audit: every table, view, and storage bucket in the public schema.
       Report which have RLS enabled, who can read, who can write, and flag any
       case where an anon or any-authenticated user can read another user's or
       another pharmacy's rows. Include the `avatars` bucket — created
       2026-08-09, default policy unverified. PRIORITY: today.
- [ ] C2. Fix whatever C1 reveals.
- [ ] C3. Report the real state of the Stripe payment rail: what is built,
       what is not, what has been tested end to end. This is the critical path
       for the September launch.
### Robert (manual)
- [ ] R1. Purge Cloudflare cache, verify the 8 Aug redesign is live.
- [ ] R2. Fill in and commit CLAUDE.md at the repo root.
- [ ] R3. Create 5 test accounts (PH-1, PH-2, LOC-1, LOC-2, ADMIN).
- [ ] R4. Run the pre-launch test plan.
- [ ] R5. One-week pilot: 2 pharmacists, 2 locums.
- [ ] R6. GST/QST treatment of the $39 fee + registration numbers on invoices.

## Open items — updated 2026-08-11

### Cowork (UI / site)
- [ ] 1. Welcome greeting next to the name, immediately after the C-Direct
      wordmark. Both the pharmacy site and the locum site, landing page and
      dashboard. Logged out: "Bienvenue"/"Welcome" alone. Logged in: with the
      first name. Must use the existing i18n mechanism — no hardcoded strings.
      STATUS: specified, not confirmed applied. VERIFY FIRST before building —
      it may already exist behind the old cache.
- [ ] 4. "Resend confirmation email" button on the login page. Needed because a
      duplicate unconfirmed user in Supabase fails silently — the user gets no
      email and no error.
- [ ] 5. This list update itself.
- [ ] 6. Brand kit installation: swap the old logo for the new C-Direct
      checkmark lockup (Anton, forest green + amber check) and install the
      favicon/app-icon set + PWA manifest from c-direct-brand-kit.zip, per its
      included handoff instructions. Separate session, own commit per step.
- [ ] 7+. Bugs from the pre-launch test pass. To come.

### Backend (separate session — full repo, database access)
- [ ] C1. RLS audit: every table, view, and storage bucket in the public
      schema. Report which have RLS enabled, who can read, who can write, and
      flag any case where an anon or any-authenticated user can read another
      user's or another pharmacy's rows. Include the `avatars` bucket —
      created 2026-08-09, default policy unverified. PRIORITY: immediate.
- [ ] C2. Fix whatever C1 reveals.
- [ ] C3. Report the real state of the Stripe payment rail: what is built,
      what is not, what has been tested end to end. Critical path for the
      September launch.
- [x] C4. Auto-accept / instant fill feature. DONE 2026-08-11: backend
      (sql/68-72, Job 1) + full UI (Batch 2, items 4-8) both live. See the
      "Pending / under review" section below for what remains before it can
      be switched on for real users.

### Robert (manual — not for any agent)
- [ ] R1. Purge Cloudflare cache, verify the 8 Aug redesign is live.
- [x] R2. Fill in and commit CLAUDE.md at the repo root. DONE 2026-08-11
      (commit 8e3d15f — strict editing rules, auto-sync kept).
- [ ] R3. Create 5 test accounts (PH-1, PH-2, LOC-1, LOC-2, ADMIN).
- [ ] R4. Run the pre-launch test plan (2–3 days).
- [ ] R5. One-week pilot: 2 pharmacists, 2 locums.
- [ ] R6. GST/QST treatment of the $39 fee + registration numbers on invoices.

## Pending / under review — 2026-08-11 (auto-accept: everything important to know)

Auto-accept is FULLY BUILT (backend sql/68-72 + UI Batch 2 items 4-8, commits
a07d82b, 4a58191, 34a02d5, 7f5f306, 330234e — one `git revert` per item to
undo) but it is DORMANT: `feature_enabled = false` platform-wide. Users see
nothing until it is switched on. Before flipping it on for real:

- [ ] P1. End-to-end test (Robert + one test locum): Admin → Auto-acceptation
      → enable + set the premium ($/h) → test locum completes Stripe
      onboarding, turns the toggle on in Paramètres with criteria, and
      confirms the month via the new banner on Mes disponibilités → post a
      matching shift from a test pharmacy → shift should book itself within
      ~30 s, premium on the contract, both parties notified.
- [ ] P2. Decide the launch premium amount. Anything above 15 $/h requires
      typing CONFIRMER [amount] — enforced by both the UI and the backend.
- [ ] P3. Kill switch awareness: "Suspendre le matching" (red toggle in admin)
      pauses all auto-acceptations instantly WITHOUT touching locum settings —
      the queue accumulates and drains on resume. This is the emergency lever.
- [ ] P4. Known small nuance, review then accept or ask for a change: editing
      the calendar auto-confirms that month in the backend, but the banner on
      Mes disponibilités only reflects it after a page reload (the button
      itself updates instantly). Left this way to avoid touching the calendar
      save code (the page stays under the do-not-touch rule; the 2026-08-11
      change was a one-time, banner-only exception).
- [ ] P5. Locum-side prerequisites worth communicating at launch: the toggle
      stays locked until Stripe onboarding is complete (charges + payouts
      enabled), and auto-accept only fires for months the locum has confirmed.
      2 cancellations of auto-accepted shifts within 90 days = 30-day
      automatic suspension.
- [ ] P6. Admin panel is French-only (whole-page convention) — the new
      Auto-acceptation section follows it. Fine for launch (admin = Robert);
      flag only if the admin console ever needs EN.

## Batch #1 closed — 2026-08-12 (QA audit fixes: all 27 tasks live)

Everything from the Aug-12 fix batch is DONE and verified in production
(details per task in FIXLOG.md): /media/911/ leak closed, bell repointed,
facture-vue rebuilt with the shared header, Agenda fully bilingual, local-date
fixes, global session-expiry handling, password re-auth, payments worker
hardened (signed Stripe webhook live, capture_failed alerts, CORS allowlist),
dual-pricing wording made legal, mobile nav/overflow/touch-target fixes,
Dispensaire admin toggle, SEO meta/OG/robots/sitemap, bilingual admin login,
auto-accept transparency (software gate + "Rejets récents"), migration
hygiene, sql/verifier-acl.sql standing check. Worker deployed
(77693be5-e87f-40f5-b1b0-a7a9a8436a33); Stripe webhook registered
(we_1U3gGYReBKCY8Yl1MLRcYK30, Connected accounts, 9 events) and verified.
sql/74–77 executed; sql/77 closed the anon leak sql/73 had reopened.

Owner decisions pending (do NOT implement without an answer):
- [ ] P-1. "Mutuellement favoris" badge on contrats.html / contrat.html while
      browsing (data already returned by get_contrats_ouverts /
      get_contrat_fiche). Yes / no?
- [ ] P-2. Auto-accept software gate: add an optional minimum proficiency
      threshold (logiciels_niveaux) or keep levels cosmetic?
- [ ] P-3. Bell destination: link now goes to /messages.html — click test not
      yet confirmed by Robert. A real notifications centre would be a new
      batch item.

Launch checklist (scheduled, not now):
- [ ] L-1. Remove/scope Cloudflare Access 2–3 weeks before the September
      launch so public pages can be indexed.
- [ ] L-2. After the first real payment event, check the Stripe destination's
      Event deliveries shows a 200.
- [ ] L-3. Standing rule: run sql/verifier-acl.sql after every future
      migration.
- [ ] L-4. 🧑 **Turn on 2FA on the five accounts that control everything.**
      Decided 2026-08-15 to do this last, right before launch. None of it is
      code — five dashboards, ~20 min total. Use the **Passwords** app already
      on the Mac to hold the codes. Do them ONE AT A TIME, finishing each
      before starting the next.
      1. **Google** (`edouardmalak@gmail.com`) — https://myaccount.google.com/signinoptions/twosv
         → 2-Step Verification → add **Authenticator**, not just SMS (SIM-swap).
         Do this FIRST: it is the recovery address for the other four.
      2. **Supabase** — https://supabase.com/dashboard/account/security →
         Multi-factor authentication → Add authenticator app. Biggest one:
         this account reads the whole database, `stripe_comptes` included.
      3. **Cloudflare** — https://dash.cloudflare.com/profile/authentication →
         Two-Factor Authentication. Cannot reveal STRIPE_SECRET_KEY but can
         REPLACE it and redeploy the site.
      4. **GitHub** — https://github.com/settings/security → Enable 2FA.
         Pushes deploy straight to the live site.
      5. **Stripe** — https://dashboard.stripe.com/settings/user → confirm
         two-step auth is on; if SMS-only, add an authenticator app.
      6. **Save all five sets of recovery codes** into the Passwords app under
         the matching login. Skipping this = locked out of your own launch if
         the phone is lost. This is the step people regret.
      NOTE: the app's OWN admin login cannot have 2FA — verified 2026-08-15,
      there is no MFA code anywhere in the repo (no `auth.mfa`, no enrollment
      or challenge screens). Supabase supports it, but it is a feature build,
      not a toggle. It only guards Robert's own admin console today, so it is
      deliberately NOT in this checklist. Ask for 2-3 design options if it is
      ever wanted.

## Open items — updated 2026-08-15 (refonte page de connexion)

- [ ] **Remplacer la photo de la page de connexion** — `media/fond-marie-eve.jpg`.
      La photo actuellement en ligne n'est PAS au Québec : vallée alpine, sommets
      enneigés en été, vignes en terrasses, chalets — vraisemblablement la vallée
      du Rhône en Valais (Suisse). Elle est affichée à 30 cm du texte « Fait au
      Québec, par un pharmacien », et la légende annonce « Marie-Ève —
      pharmacienne remplaçante » sur un paysage sans personne. Robert confirme
      en détenir les droits ; le problème est la crédibilité, pas la licence.
      Elle est aussi trop petite : 800 × 533, donc étirée ~1,7× sur un écran
      1440 px et visiblement floue.
      À fournir : une vraie scène québécoise, idéalement une pharmacienne ou un
      village rural, **1600 px de large minimum**, droits détenus.
      Remplacer le fichier au même chemin et pousser — aucun code à toucher.
      Décidé le 2026-08-15 : on garde la photo actuelle en attendant.

- [ ] **Message d'erreur de connexion en anglais sur la page française** —
      un échec de connexion affiche le texte brut de Supabase, p. ex.
      « missing email or phone », même en français. Bogue PRÉEXISTANT, sans
      rapport avec la refonte (le code d'erreur n'a pas été modifié).
      Correctif : traduire les codes d'erreur Supabase via `cdT()` dans
      `acces.html` avant le lancement.

- [ ] **Tutoiement / vouvoiement incohérent** — la nouvelle page de connexion
      tutoie (« Connecte-toi à ton espace ») alors que le reste du site vouvoie
      (18 occurrences de « vous/votre » dans `index.html` + `acces.html`, zéro
      tutoiement). Laissé tel quel : le brief demandait de ne pas toucher aux
      textes. Trancher avant le lancement, puis appliquer dans les deux langues.

## Open items — updated 2026-08-18 (vidage des tests + frais de plateforme)

- [ ] **REMETTRE LE PLANCHER TARIFAIRE À 120 $/h** — abaissé à **0,01 $/h** le
      2026-08-18 pour pouvoir publier un quart d'essai à 0,19 $/h et tester le
      prélèvement carte à 50 ¢. Tant que ce n'est pas remis, n'importe quelle
      pharmacie peut publier un quart à n'importe quel prix.
      Administration → Règles du réseau → Tarif horaire minimum → `120` →
      Enregistrer. (Ou en SQL : `update public.regles_reseau set
      tarif_horaire_minimum = 120 where id = 1;`)

- [ ] **REMETTRE LES FRAIS DE PLATEFORME À 39 $ AVANT LE LANCEMENT** — posés à
      **0 $** le 2026-08-18 pour la phase de test (sql/82). À 0 $, C-Direct ne
      facture rien : la pharmacie ne paie que le montant du pharmacien plus les
      frais de carte. Administration → Frais de plateforme → `39` → Enregistrer.
      Aucun redéploiement nécessaire : le Worker relit la valeur en base à
      chaque autorisation.

- [ ] **`fsa-qc.js` affiche encore 39 $ en dur** — `window.cdPrixDual()` garde
      `const FRAIS_CDIRECT = 39` alors que le montant réellement prélevé vient
      maintenant de la base. Volontairement PAS touché le 2026-08-18 : cette
      fonction n'est appelée nulle part aujourd'hui (double tarification pas
      encore branchée sur un écran). À rebrancher sur `public.frais_plateforme()`
      le jour où l'écran de réservation affichera les deux prix — sinon le site
      annoncera un prix et en prélèvera un autre.

- [ ] **Le Worker `c-direct-payments` ne se déploie PAS depuis GitHub** —
      confirmé au tableau de bord Cloudflare le 2026-08-18 : les 6 dernières
      versions sont toutes « Manually deployed / Wrangler ». Après TOUT
      changement dans `workers/c-direct-payments/src/index.js`, il faut lancer
      `npx wrangler deploy` depuis le dossier du Worker. Les deux autres Workers
      (`c-direct-sms`, `c-direct-chat`) se déploient bien automatiquement.

- [ ] **Base vidée le 2026-08-18 (sql/81)** — 97 contrats, 41 candidatures,
      5 garanties, 813 SMS journalisés et 175 SMS en file effacés. Comptes,
      carte de garantie, compte connecté Stripe et calendriers conservés.
      Le compteur de références repart à **CD-100001**. Irréversible : le point
      de restauration git `restore-2026-08-18-avant-flush-tests` ne couvre que
      les fichiers, pas les données.

## Bogues du test de paiement du 2026-08-18 — TOUS CORRIGÉS (sql/83)

Trouvés pendant le premier passage d'argent réel, corrigés le jour même.
Migration `sql/83-corrections-garanties.sql` exécutée, Worker redéployé.

- [x] **L'heure des quarts était interprétée en UTC** — CORRIGÉ. La base
      tourne en UTC et les quarts sont stockés en date + heure nue, donc
      `(date_contrat + heure_debut)::timestamptz` résolvait en UTC : un quart
      publié pour 8 h du matin à Montréal était vu comme 8 h UTC, soit 4 h du
      matin heure locale. Toute la mécanique T-24 h et l'échelle de relance
      (T-18h / T-12h / T-6h) était décalée de 4 heures (5 l'hiver), et un quart
      tôt le matin pouvait sortir de la fenêtre sans jamais être autorisé.
      `lister_candidatures_a_autoriser` utilise maintenant
      `at time zone 'America/Toronto'`, la convention déjà suivie partout
      ailleurs (sql/09, sql/28, sql/68, sql/70) — le bloc « garanties » était
      le seul à y échapper. Vérifié après migration : un quart à 08:00 résout
      désormais à 12:00 UTC, écart de 4 h corrigé.

- [x] **Le filet de capture se déclenchait pour des quarts qui n'ont jamais
      eu lieu** — CORRIGÉ. `lister_garanties_a_capturer` capturait dès que
      `capture_before <= now() + 6 h`, sans aucune condition sur le quart.
      Une garantie posée sur un quart annulé, ou dont la feuille de temps n'a
      jamais été soumise, finissait par débiter la carte ~7 jours plus tard
      pour un travail non effectué. Le filet est conservé — il protège le
      pharmacien dont la pharmacie ne donne plus signe de vie — mais exige
      désormais que le quart soit **réellement terminé** (heure de fin passée,
      quart de nuit géré) et que le contrat ne soit pas annulé. Un quart qui
      n'a pas eu lieu laisse simplement l'autorisation expirer, sans frais.

- [x] **Le journal perdait l'affichage de la ligne « captured »** — CORRIGÉ.
      `capturerGarantie()` journalisait avec `ancien_statut = null`, donc toute
      concaténation `ancien || '->' || nouveau` valait NULL et la ligne
      disparaissait des relevés — précisément dans la table qui sert de preuve
      en cas de contestation de carte. La RPC renvoie maintenant le statut de
      départ et le Worker le transmet, pour `captured` comme pour
      `capture_failed`.

## Construit le 2026-08-18 — soir (sql/85 à 89)

- [x] **Machine à états appliquée PAR LA BASE** (sql/85) — table des
      transitions légales + déclencheur. Atteindre `confirmed_exact` (l'état
      qui annule la garantie) exige de nommer QUI a confirmé, et la base
      vérifie que c'est le pharmacien du mandat. Une pharmacie ne peut plus
      libérer sa propre garantie, même si le code le tentait.
- [x] **Suite de 11 assertions** (sql/86) — non destructive, se termine par
      ROLLBACK, relançable en production à tout moment.
- [x] **Verrou SKIP LOCKED + idempotence sur la capture** (sql/87) — la
      capture n'avait AUCUNE clé d'idempotence : deux cycles simultanés
      capturaient une fois, puis le second lisait « already captured » comme
      un échec, passait en capture_failed et alertait la pharmacie par SMS
      pour un paiement réussi.
- [x] **Pointage arrivée/départ** (sql/88) — tout en RPC, donc l'app Flutter
      appellera les mêmes fonctions. Position vérifiée puis JETÉE : la table
      ne peut stocker ni coordonnée ni image (Loi 25).
- [x] **Avenants d'heures et financement** (sql/89) — baisse financée seule
      par capture partielle, hausse soumise à l'accord de la pharmacie avec
      délai de 3 h, départ oublié pointé automatiquement à fin prévue + 2 h.

- [ ] **Position exacte des pharmacies** — la base n'a AUCUNE coordonnée de
      pharmacie, seulement le centroïde de RTA (3 premiers caractères du code
      postal), qui couvre plusieurs kilomètres en ville et beaucoup plus en
      région. La vérification de présence est donc de l'ordre du quartier.
      Colonnes `profiles.latitude/longitude` ajoutées et vides : un bouton
      « enregistrer la position de ma pharmacie », pressé sur place depuis
      l'appareil du propriétaire, ferait passer la précision de kilomètres à
      mètres. Aucun service de géocodage, aucune dépendance.

- [ ] **Une hausse d'heures approuvée n'est PAS couverte par la garantie** —
      Stripe interdit d'augmenter une autorisation déjà posée
      (docs.stripe.com/api/payment_intents/capture : « must be less than or
      equal to the original amount »). Le surplus est enregistré dans
      `supplement_du_cents` et doit être réglé à part. À décider : facturation
      séparée, ou autorisation avec marge dès le départ.

## 🧑 DÉCISION EN SUSPENS — le virement instantané ne couvre PAS Desjardins

Vérifié le 2026-08-18 sur la liste officielle de Stripe
(docs.stripe.com/payouts/instant-payouts-banks, Canada). Stripe écrit noir sur
blanc : « **Only the listed institutions support Instant Payouts.** »

**Toute la liste canadienne tient en 10 institutions :**

| Toutes les cartes de débit | Certaines cartes seulement |
|---|---|
| Tangerine | CIBC |
| Banque Scotia | RBC |
| ATB Financial | TD |
| ICICI Bank Canada | Servus Credit Union |
| Windsor Family Credit Union | |

**Desjardins n'y est pas. Ni la Banque Nationale, ni BMO, ni la Laurentienne.**
Recherché sous toutes les variantes (Caisse, Desj, Fédération, Mouvement,
Québec, Banque) — aucun résultat. ATB et Servus sont albertaines, Windsor
Family est ontarienne.

Pour un marché de pharmaciens **québécois**, c'est un trou sérieux : Desjardins
représente environ la moitié du marché de détail au Québec. Un pharmacien qui
fait affaire avec une caisse **ne peut PAS recevoir de virement instantané**, et
aucun contournement n'existe chez Stripe. Rappel : au Canada l'instantané ne va
qu'à une **carte de débit**, jamais à un compte bancaire.

**L'ironie à garder en tête :** Interac atteignait TOUTES les banques
canadiennes, Desjardins compris, en ~30 minutes. Il a été éteint (sql/84) en
partie sur l'idée que carte + virement instantané serait strictement meilleur.
Ce n'est vrai que pour les pharmaciens des bonnes institutions.

**Aucune urgence technique :** `verserInstantanement()` tente l'instantané,
retombe sur le versement standard et journalise la raison. Un pharmacien
Desjardins est payé au calendrier normal, rien ne casse. Et Interac dort
derrière un interrupteur admin, code intact — le rallumer est un clic.

**Options :** (a) inviter les pharmaciens à ajouter une carte Tangerine ou
Scotia, (b) rallumer Interac pour les pharmaciens Desjardins, (c) assumer deux
vitesses et le dire clairement, (d) d'abord mesurer où les pharmaciens font
réellement affaire.

**Recommandation :** ne pas mettre « toujours instantané » en titre. Mettre
**paiement garanti** — c'est universel, et c'est précisément ce que le
concurrent refuse par écrit. Afficher à chaque pharmacien si SA carte est
admissible, grâce au cache `paiement_instantane_pret` rempli dès T-24h.

---

## 🔒 Audit de sécurité — Bloc 1 / Phase 1 — mis en pause au Gate 1 (2026-08-21)

Rapport complet : `.internal/security/PHASE1-RESULTATS.md` (dans le dépôt, jamais déployé).
Le Bloc 2 (auto-acceptation) NE DÉMARRE PAS tant que ces points ne sont pas réglés.

### 🔴 Bloquant pour le lancement

1. 🧑 **Les frais de plateforme sont à 0 EN PRODUCTION.** Vérifié en direct le
   2026-08-19 : `frais_plateforme()` renvoie `0` et `reglages_paiement()` confirme
   `frais_cdirect_dollars: 0`. `sql/82` sème la valeur à 0 (`on conflict do nothing`)
   et personne ne l'a jamais remontée. **Si le site lançait aujourd'hui, chaque quart
   serait facturé 0 $.** À remettre à **39** avant le lancement (réglage admin ou un
   simple UPDATE sur `parametres_plateforme`). Hors périmètre de l'audit : touche au
   paiement, donc laissé à Robert.

2. ✅ **RÉGLÉ 2026-08-21 — la réinitialisation de mot de passe était CASSÉE sur `cdirect.quebec`.**
   Le domaine manquait dans la liste blanche des URL de redirection Supabase : le jeton de
   récupération atterrissait sur l'accueil, qui ne le traite pas. Tout usager ayant oublié son
   mot de passe restait bloqué dehors. `https://cdirect.quebec/**` ajouté par Robert, puis
   **vérifié de bout en bout** : courriel demandé, lien ouvert sur la vraie page « Nouveau mot
   de passe », mot de passe changé, session ouverte. (Le code d'`acces.html` était correct —
   c'était de la configuration.) À savoir : un lien de récupération est à usage unique et
   expire ; un vieux courriel donne `otp_expired`. Toujours utiliser le plus récent.

### 🟠 À trancher / à appliquer

3. 🧑 **Domaine canonique : `c-direct.ca` ou `cdirect.quebec` ?** Le Site URL dit
   `c-direct.ca` mais le trafic atterrit sur `cdirect.quebec`. Ce Site URL sert de
   repli à TOUS les courriels d'authentification. À aligner avant le lancement.

4. 🤖 **`sql/91` — durcissement du bucket `avatars`** (rédigé, EN ATTENTE, non appliqué,
   déposé en `.internal/security/91-avatars-durcissement.sql.EN-ATTENTE`). Deux correctifs :
   · **listage anonyme** : vérifié en direct le 2026-08-19, `POST /storage/v1/object/list/avatars`
     répond **200 sans aucune session**. Le bucket est vide aujourd'hui, mais dès qu'un locum
     dépose une photo, n'importe qui peut énumérer les noms de dossiers = les UUID des usagers.
   · **téléversements non validés côté serveur** : le bucket accepte « Any » jusqu'à 50 Mo,
     alors que `profil.html` promet 3 types d'images et 2 Mo — ces contrôles sont dans le
     navigateur donc contournables. Correctif : 2 Mo + `image/png,image/jpeg,image/webp`
     (SVG volontairement exclu : peut porter du script).
   → À appliquer APRÈS un téléversement de photo réussi, pour prouver avant/après que
   l'affichage des avatars n'est pas cassé.

5. 🧑 **Décision dispensaire — il est invisible aux visiteurs déconnectés.** La politique
   `articles` est `publie = true or est_admin()` ; comme `anon` ne peut pas exécuter
   `est_admin()`, tout le prédicat échoue et un visiteur non connecté reçoit 401. Les
   articles publiés ne sont donc lisibles ni par le public ni par Google. Sûr (fermé par
   défaut) mais probablement pas l'intention si le dispensaire doit servir au référencement.
   Se règle en même temps que la décision « dispensaire visible ou caché au lancement ».

### ⏸️ Reste à faire — côté pharmacie seulement

6. ✅ **Matrice croisée — CÔTÉ LOCUM RÉUSSI (2026-08-21).** Testé en direct avec une vraie
   session `edouardmalak+locumA` (locum inscrit, **non approuvé** — donc l'attaquant le plus
   facile à devenir : n'importe qui crée un compte en deux minutes). Résultats :
   · `SELECT *` non filtré sur `profiles` (9 usagers en base) -> **1 seule ligne, la sienne**.
     Aucun nom, courriel, téléphone ni permis OPQ d'autrui. C'est LA table équivalente à celle
     qui a fuité chez xPayrience — elle est correctement isolée.
   · lecture du profil de l'ADMIN par uid -> **0 ligne**.
   · `contrats`, `candidatures`, `messages`, `factures`, `garanties_paiement`,
     `stripe_comptes`, `sms_log` non filtrés -> **0 ligne** partout.
   · **écriture** sur le profil d'un autre usager (ligne qui existe bel et bien) ->
     **0 ligne modifiée**. Aucune donnée touchée.
   -> Les deux chemins réalistes de fuite massive (sans session, et avec un compte libre-service)
   sont donc fermés, prouvés sur données réelles.

7. ✅ **CÔTÉ PHARMACIE RÉUSSI AUSSI (2026-08-22).** Compte `pharmP` confirmé par courriel puis
   connecté. Résultats, session réelle rôle `pharmacie` :
   · `SELECT *` non filtré sur `profiles` (9 usagers) -> **1 seule ligne, la sienne**
   · profil de l'AUTRE pharmacie (`+pharmacie@`, compte de juillet avec vraies données) -> **0 ligne**
   · `contrats`, `factures`, `locum_pharmacy_relations`, `garanties_paiement`,
     `candidatures`, `messages` non filtrés -> **0 ligne** partout
   · `get_contrat_fiche('CD-100001')` (contrat d'une autre partie) -> **0 ligne**
   · **écriture** sur le profil de l'autre pharmacie -> **0 ligne modifiée**
   -> **La tâche 1.1 est TERMINÉE.** Les trois profils d'attaquant réalistes ont été essayés
   en production avec une vraie session — aucun n'obtient les données d'autrui :

   | Attaquant | Lecture d'autrui | Écriture chez autrui |
   |---|---|---|
   | Aucune session (anonyme) | NON — 47 tables sur 47 | NON |
   | Locum inscrit non approuvé | NON — 1 profil sur 9 | NON — 0 ligne modifiée |
   | Pharmacie confirmée | NON — 1 profil sur 9 | NON — 0 ligne modifiée |

8. **À retester quand un quart sera publié :** `get_contrats_ouverts()` appelé par un locum NON
   approuvé répond 200 avec 0 ligne — impossible de distinguer « l'approbation bloque » de
   « la base est vide ». Le code ne vérifie `est_approuve()` qu'à l'INSERT (publier un quart,
   postuler), jamais en lecture. Un compte non vérifié peut donc probablement parcourir le
   marché des quarts. C'est peut-être voulu (montrer la valeur avant approbation) et le
   sensible est protégé : la fonction renvoie ville, code postal et tarif mais **jamais** le nom
   ni l'adresse de la pharmacie. À confirmer comme décision produit.

### ✅ Réglé pendant ce gate (pour mémoire, aucune action)

- `/media/911/` (handoff de refonte, 845 Ko) était **servi publiquement** → déplacé dans
  `.internal/`, dossier en point que Cloudflare Pages ne déploie jamais + garde CI qui fait
  échouer le build si un document interne réatterrit à un chemin public. Commit `c4674cc`.
- **Accès anonyme : 47 tables sur 47, ZÉRO fuite.** Liste des tables vérifiée contre le schéma
  live (correspondance exacte, aucune table fantôme créée à la main hors migration).
- **Les fuites historiques `sql/63` et `sql/73` sont confirmées FERMÉES en production**
  (`get_contrats_ouverts`, `get_contrat_fiche`, `aa_horaire_libre`, `get_stats_pharmacien`,
  `get_note_profil` : 401 pour un appelant anonyme).
- **Aucun secret n'a jamais été commité** sur les 423 commits de l'historique.

---

## ⏸️ REPORTÉ — test bout en bout de la photo de profil (marqué le 2026-08-22)

**Décidé par Robert : reporté, pas oublié.**

Le bucket `avatars` est passé en PRIVÉ (sql/94) et `profil.html` affiche désormais la photo
via une URL signée (1 h) au lieu d'une URL publique. Le bucket étant **vide**, ce chemin n'a
jamais été parcouru en conditions réelles : le téléversement, l'enregistrement du CHEMIN dans
`profiles.photo_url`, puis l'affichage signé après rechargement n'ont pas été testés ensemble.

**Ce qui est déjà prouvé :** le bucket est bien privé (le chemin public répond `NoSuchBucket`
alors que le bucket existe), les limites 2 Mo / png-jpeg-webp sont actives, et la politique de
lecture réservée au propriétaire est en place.

**Ce qui reste à faire (2 minutes) :**
1. Se connecter, aller sur `/profil`
2. Téléverser une photo, enregistrer
3. Recharger la page : la photo doit toujours s'afficher

**Risque si on l'oublie :** si l'URL signée échoue, la photo de profil ne s'affiche plus —
gêne cosmétique, aucune conséquence de sécurité ni de paiement. À faire avant que de vrais
locums déposent des photos.

**Rappel utile :** `photo_url` contient désormais le CHEMIN (`<uid>/photo.jpg`) et non plus une
URL. Les anciennes valeurs en URL complète restent reconnues — mais il n'y en a aucune, le
bucket n'ayant jamais servi.

---

## ✅ Redirection de domaine CORRIGÉE — 2026-08-22

**Le problème.** `c-direct.ca` redirigeait (301) vers `cdirect.quebec`. Le domaine canonique
retenu cédait donc tout son trafic et son indexation Google à l'autre — l'inverse de
l'intention, et contraire à l'équité de marque bâtie sur le `.ca`.

**Ce qui a été fait (tableau de bord Cloudflare) :**

1. Zone `c-direct.ca` → la règle « Redirect to cdirect.quebec (primary domain) » est
   **DÉSACTIVÉE** (et non supprimée : réversible en un clic si besoin).
2. Zone `cdirect.quebec` → nouvelle règle **« Redirect to c-direct.ca (primary domain) »**,
   301, toutes requêtes, `concat("https://c-direct.ca", http.request.uri.path)`, chaîne de
   requête préservée.

**Pourquoi « toutes les requêtes » plutôt qu'un filtre de nom d'hôte :** la règle vit dans la
zone `cdirect.quebec`, donc elle ne voit QUE le trafic de ce domaine — `cdirect.quebec` et
`www.cdirect.quebec` sont couverts d'office, sans logique OU à se tromper. Les Workers
tournent sur `*.workers.dev`, hors zone : rien d'autre n'est intercepté.

**Ordre respecté volontairement :** désactiver l'ancienne règle AVANT de créer la nouvelle.
L'inverse aurait créé une boucle de redirection infinie entre les deux domaines et rendu le
site inaccessible.

**Vérifié en production, cache contourné :**
- `cdirect.quebec/faq` → `c-direct.ca/faq` (chemin conservé, bonne page)
- `c-direct.ca/faq` → sert directement, plus aucune redirection
- `c-direct.ca/nouveaux` → `c-direct.ca/acces?mode=conn` (garde d'authentification normale,
  on reste bien sur le `.ca`)
- aucune boucle

**Les 4 domaines restent des domaines personnalisés actifs sur le projet Pages** — c'est ce
qui permet au `.ca` de servir le site directement.

**À faire un jour, pas urgent :** enregistrer `cdirect.ca` (la faute de frappe évidente du
domaine) et le rediriger vers `c-direct.ca`.
