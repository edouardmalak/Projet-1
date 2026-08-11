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

## 1. Right now — Stripe live mode

You just activated your live Stripe account (correctly chose not to copy sandbox data over). The app itself hasn't moved to live keys yet — it's still running on test keys, on purpose, until you're ready. Four steps left:

1. 🧑 **Confirm Stripe's live verification is actually finished** — not just that you're "in" live mode. In the Stripe dashboard (live mode), check that your account shows `charges_enabled` and `payouts_enabled` as true. If Stripe is still asking for business info or bank details, that's not done yet.
2. 🧑 **Swap the live secret key into the Worker.** Cloudflare → Workers & Pages → `c-direct-payments` → Settings → Variables and Secrets → edit `STRIPE_SECRET_KEY` → paste the **live** key (starts `sk_live_...`) → Save. Then, from your own terminal: `cd workers/c-direct-payments && git pull && npx wrangler deploy` (this Worker does not auto-deploy from git push — you have to run this yourself, same as before).
3. 🧑 **Every pharmacist redoes Stripe Connect onboarding for real.** Test-mode connected accounts don't carry over — Stripe treats live mode as a completely separate space. Each pharmacien needs to go through onboarding again from `profil.html` once live keys are in.
4. 🧑 **Every pharmacy re-enters a real card.** Same reason — test cards don't exist in live mode.

Tell me when you want to do #2 and I'll walk through it with you or make any code changes needed first.

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

- 🧑 **Admin 2FA** — turn on two-factor for the admin account(s), both the Supabase dashboard login and the app's own admin login.
- 🧑 **Supabase auth emails** — password reset / signup confirmation still use Supabase's built-in email sender, which is rate-limited. Worth wiring a custom SMTP (you already have a working Resend account/domain from the confirmed-contract emails) before real signup volume hits.
- 🧑 **Supabase backups** — confirm daily backups are actually turned on (Project → Database → Backups) and note the retention window.
- 🧑 **Twilio low-balance alert** — set one up so broadcast SMS never silently fail on an empty balance.
- 🤖/🧑 **`espace-pharmacien.html` — is it safe to delete?** Flagged back on 2026-07-30: this page has no Supabase includes and nothing links to it (`contrats.html` is the real pharmacien landing page). Still sitting in the repo unused. Just needs a yes/no from you.
- 🤖 **Remove the temporary `/diag` endpoint** on the `c-direct-chat` Worker — cleanup only, low priority.
- 💤 **Welcome SMS on opt-in** — spec'd but never built (deliberately — needs a new profiles-UPDATE webhook + Worker handler on the live SMS Worker, hasn't felt worth the risk untested). Still just an idea, not started.

---

## 6. Explicitly deferred (decided already, not forgotten)

These came up during the payments build and were consciously left out rather than missed:

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
- [ ] C4. Auto-accept / instant fill feature: locum opts in with settings
      (max km, max hours per shift, minimum rate, must-know-software), and
      matching shifts book instantly; per-hour premium on auto-accepted
      shifts, amount set globally in admin; schedule-conflict check required.
      STATUS: to be specified in detail before any code — do not start from
      this line alone.

### Robert (manual — not for any agent)
- [ ] R1. Purge Cloudflare cache, verify the 8 Aug redesign is live.
- [ ] R2. Fill in and commit CLAUDE.md at the repo root.
- [ ] R3. Create 5 test accounts (PH-1, PH-2, LOC-1, LOC-2, ADMIN).
- [ ] R4. Run the pre-launch test plan (2–3 days).
- [ ] R5. One-week pilot: 2 pharmacists, 2 locums.
- [ ] R6. GST/QST treatment of the $39 fee + registration numbers on invoices.
