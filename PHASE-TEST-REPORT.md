# C-Direct — Phase-by-phase test report

**Tested:** 2026-07-19 · live site `projet-1-1yi.pages.dev` + live Supabase.
**Method:** browser tests as the logged-in **admin** account, database checks via the app's Supabase client, anonymous-client RLS checks, code review, and JS/SQL syntax checks. I could **not** authenticate as the pharmacien/pharmacie accounts (entering passwords to sign in is not something I'm allowed to do), so role-restricted *live* actions are marked "needs you."

## Restore points (git tags, none deleted)
`restore-before-phase-tests` · `restore-phase-1` · `restore-phase-2` · `restore-phase-3` · `restore-phase-4` · `restore-phase-5`
Roll back to any of them with, e.g.: `git reset --hard restore-phase-1 && git push --force`. (Ask me and I'll do it.)

---

## Phase 1 — Foundations ✅ PASS
- **Schema (1.2):** all 8 tables present live (profiles, contrats, candidatures, factures, disponibilites, favoris, regles_reseau, sms_log); every column present; CD-reference sequence works (test contract auto-numbered **CD-100012**); `regles_reseau` has the exact plan defaults (120 / 0,70 / 50 / 250 / 100 / 100 / 50 / 100 / 30).
- **RLS (1.3):** anonymous client returns **0 rows on every table** — no leakage. `est_admin()` is a security-definer function. Policies reviewed and correct.
- **Auth (1.1):** signup (role/nom/prénom/tél/consent), login, password reset, email confirmation + resend, Google OAuth button, persistent session + redirect-back, `supprimer_mon_compte` (cascade delete) — all implemented and wired.
- **Board + detail (1.4):** board lists open contracts; `/c/CD-100012` detail route works and shows every field.
- **Admin console:** working (the "Valider" button bug you reported earlier is fixed).

**Needs you (live):** signing up/logging in as the pharmacien & pharmacie accounts; completing Google OAuth setup in Google Cloud + Supabase; the "100 $/h is blocked" check (the DB floor trigger correctly exempts admins, so it only fires under a pharmacie session).

## Phase 2 — Workflow ⚠️ GAPS FOUND → FIXED
- **2.1 Two-speed apply** ✅ present (instantanée + négociée with schedule counter).
- **2.2 Negotiation + timeline** ✅ RPCs (`accepter_candidature`, `accepter_contre_offre`) + jalon timeline present; `accepter_candidature` correctly accepts one and auto-refuses the others.
- **2.3 Distance + money math** ❌ was **not wired** (the `fsa-qc.js` engine was loaded by no page; apply never stored `distance_km`) → **FIXED:** loaded the engine on the board + detail, the detail page now shows "tarif × heures … Total estimé", and apply now stores `distance_km`. Defensive: shows base math immediately; km/per-diem/lodging light up once postal codes are available.
- **2.4 Board upgrades** ❌ were **not present** → **FIXED:** added filters (ville, tarif min, logiciel, distance max) + sort (récents / date / tarif / distance) + a "≈ total" estimate line per row. Verified working live.
- **Still deferred (lower value):** favoris/bookmarks, the Disponibles/Mes candidatures/Confirmés tabs, and the pharmacy "responsiveness" median stat.

**⚠️ ACTION FOR YOU (1 paste):** run **`sql/13-distance-code-postal.sql`** in Supabase → SQL Editor. It exposes the pharmacy's postal code to the board/detail so real distances compute. Until you run it, nothing breaks — you just see base totals without km.

## Phase 3 — Money ✅ PASS (code-complete, error-free)
- `marquer_complete` generates the brouillon invoice from the accepted candidature: heures from the agreed schedule, **km = distance_km × 2** at the network rate, per-diem/lodging from the contract flags — idempotent. (My Phase 2.3 fix is what makes the km populate.)
- `envoyer_facture` / `envoyer_factures_mois` (batch) / `marquer_facture_payee` present; `pg_cron` job "factures-en-retard" scheduled; `annuler_contrat_pharmacie` auto-issues the penalty invoice; `admin_maj_facture_statut` for the admin override.
- **Règles du réseau** page: no errors, every number matches the DB. mes-mandats & espace-pharmacie pages load clean.

**Needs you (live):** generating a real invoice requires an attributed + past contract with an accepted candidature (needs the pharmacien/pharmacie logins).

## Phase 4 — SMS core ✅ DEPLOYED · live SMS test pending
- Worker `workers/c-direct-sms` (928 lines) syntax-clean: endpoints `/test`, `/webhook`, `/twilio-inbound`; Twilio via fetch; logs to `sms_log`; idempotency.
- **Deployed 2026-07-18** at `https://c-direct-sms.edouardmalak.workers.dev` (via Cloudflare Workers Builds git integration — every push to main also rebuilds it). All 6 secrets set; Twilio number **+14504009628** (Québec 450, trial account ~$15.50 credit). ⚠️ The live pipeline means **any contract INSERT now broadcasts** to opt-in pharmacists — currently none have `sms_optin=true` + a verified number, so nothing was sent when I created the test contract.
- **Needs you (live test):** admin "SMS test" button → your phone (costs a little Twilio credit; trial can only text *verified* numbers). The `/twilio-inbound` webhook is **not** configured (optional — carrier handles STOP/ARRET; ours only syncs opt-out to the DB). Consider rotating the Twilio Auth Token (it may have been briefly exposed on 2026-07-18).

## Phase 5 — SMS intelligence ✅ DEPLOYED · live SMS test pending
- Worker cron triggers (queue flush every minute, payment dunning, rappel-veille) + `sms_queue`/`sms_batch` tables + filtered-broadcast/grouping SQL — present, syntax-clean, and deployed (all 5 crons active).
- Supabase webhooks configured 2026-07-18: contrats INSERT + UPDATE, candidatures INSERT+UPDATE, factures UPDATE → the Worker.
- **Needs you (live test):** exercising the lifecycle matrix end-to-end needs the pharmacien/pharmacie logins + a verified phone with Twilio credit.

---

## Test data left in place
- **CD-100012** — one labelled open test contract (notes: "TEST-COWORK…"), kept so you can *see* the new board filters/estimate and detail page working. Delete anytime (or tell me and I'll remove it).

## Your to-do list when you're back
1. Run `sql/13-distance-code-postal.sql` in Supabase (lights up real distances on the board/detail).
2. Log in as the pharmacien & pharmacie test accounts and run the Phase 1–3 live checks (apply → accept → complete → invoice → pay; cancellation penalty). Setting postal codes on both test profiles first makes the distance/allowance math visible.
3. Live SMS test: admin "SMS test" button → your phone (verify your number in Twilio / add credit first). Optionally configure `/twilio-inbound` and rotate the Twilio Auth Token.
4. Decide if you want the deferred Phase 2.4 extras (favoris, tabs, responsiveness stat) built.
