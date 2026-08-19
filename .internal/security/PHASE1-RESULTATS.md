# C-Direct — Phase 1 Adversarial Access Audit — RESULTS

**Date:** 19 August 2026
**Scope:** Block 1 / Phase 1 of the security handoff (Tasks 1.1–1.4). BLOCKING gate.
**Status:** Static layer COMPLETE. Empirical (live-run) layer PENDING — needs items from Robert (§7).
**⛔ This is the Gate 1 file. All other blocks are stopped until you review it.**

---

## 0. How to read this

Phase 1 has two layers:

- **Static layer** — read every one of the 93 migrations, extract every table, every policy, every grant, and judge the *definitions*. I can do this fully, offline. It is complete and below.
- **Empirical layer** — authenticate as real test users and actually *attempt* the forbidden reads/writes, observing DENIED vs ALLOWED. The handoff requires this; a policy that looks right can still behave wrong. I could not run it: my sandbox cannot reach Supabase (only GitHub is allowlisted), and I have no test-user credentials. The runnable script is delivered and ready; §7 lists exactly what you supply to complete it.

A clean static layer is necessary but **not sufficient** to declare Phase 1 PASS. Treat the overall gate as **PASS-pending-empirical**.

---

## 1. Verdict summary

| Task | What | Result |
|---|---|---|
| 1.1 static | RLS + policy definitions across all 47 tables | **PASS** (see §2) |
| 1.1 empirical | Adversarial run of the access matrix | **PENDING** — script ready, needs §7 |
| 1.2 | Storage bucket audit | **PASS with 1 item to confirm live** (§3) |
| 1.3 | Public-asset sweep (/media/911/ class) | **FAIL → FIXED & VERIFIED 19 Aug** (§4) |
| 1.4 | Secret hygiene, full git history (423 commits) | **PASS** (§5) |

No leak of the sql/73 class (anon-executable SECURITY DEFINER RPC) survives in the migrations: sql/77 revoked all three. That was the highest-severity historical finding and it is closed in code — the empirical run confirms it live.

---

## 2. Task 1.1 — Table RLS + policy inventory (static)

**Table list source:** the 93 committed migrations (`sql/*.sql`). The *authoritative* list must come from the live schema — the empirical run regenerates it via `list_public_tables()` so a table created outside these files can't be skipped. From the migrations, **47 base tables**, **all with `ENABLE ROW LEVEL SECURITY`**. Zero tables created without RLS.

Owner-scoping spot-checked on the highest-sensitivity tables and confirmed correct:

- `profiles` — `id = auth.uid() or est_admin()` on select/update; insert `with check (id = auth.uid())`.
- `stripe_comptes` — select `profil_id = auth.uid() or est_admin()`; **no client write policy** (service-role only). A user cannot forge a Stripe id.
- `garanties_paiement` / `_journal` — select scoped to the two contract parties via candidature→contrat join; **no client write policy** (Worker/service-role only). Correct: payment state is never client-writable.
- `contrats`, `candidatures`, `factures`, `messages`, `disponibilites`, `locum_pharmacy_relations` — owner/party-scoped select; admin via `est_admin()`.

**Deny-all by design (RLS on, zero policy → nothing reachable by any client):** `file_notifications`, `matching_queue`, `stripe_evenements`. All three are internal queue/event tables written by SECURITY DEFINER functions. Correct and intentional — flagged only so the empirical run confirms no RPC leaks their contents.

**Only `USING(true)` (open) policies:** `meteo_cache` (weather cache) — intended public. See §6.

Per-table inventory (RLS = enabled; Pol = policy count; Cmds = commands covered):

| Table | RLS | Pol | Cmds |
|---|---|---|---|
| admin_audit_log | YES | 1 | SELECT |
| annulations_auto_acceptation | YES | 1 | SELECT |
| articles | YES | 2 | ALL, SELECT |
| auto_accept_admin_settings | YES | 1 | SELECT |
| auto_accept_admin_settings_history | YES | 1 | SELECT |
| auto_accept_locum_settings | YES | 3 | INSERT, SELECT, UPDATE |
| avenants | YES | 1 | SELECT |
| candidatures | YES | 6 | SELECT, INSERT, UPDATE, DELETE |
| contrat_notes_admin | YES | 1 | ALL |
| contrats | YES | 5 | SELECT, INSERT, UPDATE, DELETE |
| demandes_contrat | YES | 2 | SELECT |
| demandes_retard | YES | 2 | SELECT |
| disponibilites | YES | 2 | ALL, SELECT |
| evaluations | YES | 1 | SELECT |
| exclusions | YES | 1 | ALL |
| factures | YES | 2 | ALL, SELECT |
| favoris | YES | 2 | ALL, SELECT |
| favoris_pharmaciens | YES | 2 | ALL, SELECT |
| fiabilite_annonce | YES | 1 | SELECT |
| file_notifications | YES | 0 | deny-all (internal) |
| fils | YES | 1 | SELECT |
| fsa_centroides | YES | 2 | SELECT |
| garanties_paiement | YES | 1 | SELECT |
| garanties_paiement_journal | YES | 1 | SELECT |
| locum_calendar_confirmations | YES | 1 | SELECT |
| locum_pharmacy_relations | YES | 1 | ALL |
| match_log | YES | 1 | SELECT |
| matching_queue | YES | 0 | deny-all (internal) |
| messages | YES | 4 | SELECT, INSERT |
| messages_admin | YES | 2 | SELECT, INSERT |
| messages_admin_etat | YES | 1 | SELECT |
| meteo_cache | YES | 3 | SELECT, INSERT, UPDATE (public — §6) |
| parametres_plateforme | YES | 1 | SELECT |
| parametres_plateforme_history | YES | 1 | SELECT |
| pointages | YES | 1 | SELECT |
| profil_notes_admin | YES | 1 | ALL |
| profiles | YES | 3 | SELECT, INSERT, UPDATE |
| push_subscriptions | YES | 3 | SELECT, INSERT, DELETE |
| regles_reseau | YES | 2 | SELECT, UPDATE |
| rendez_vous | YES | 2 | SELECT, INSERT |
| revenus_externes | YES | 1 | ALL |
| sms_batch | YES | 1 | ALL |
| sms_log | YES | 1 | ALL |
| sms_queue | YES | 1 | ALL |
| stripe_comptes | YES | 1 | SELECT |
| stripe_evenements | YES | 0 | deny-all (internal) |
| verification_interac | YES | 1 | SELECT |

**Adversarial matrix — empirical status (to be filled by the live run):**

| Acting as | Attempts | Expected | Static read | Empirical |
|---|---|---|---|---|
| Locum A | Locum B profile / messages / contracts / invoices | DENIED | scoped ✓ | PENDING |
| Locum A | Pharmacy private fields pre-confirmation | DENIED | scoped ✓ | PENDING |
| Pharmacy P | Pharmacy Q contracts / relations / invoices | DENIED | scoped ✓ | PENDING |
| anon | every table one by one | DENIED except public | scoped ✓ | PENDING |
| anon | every RPC / Edge Function | DENIED except auth | sql/77 ✓ | PENDING |
| Locum A | UPDATE/DELETE rows not owned | DENIED | scoped ✓ | PENDING |
| Any | four-state relations of another pair | DENIED | scoped ✓ | PENDING |

"Static read ✓" = the policy definition scopes it correctly. "PENDING" = not yet proven against live data. The script tests every cell.

---

## 3. Task 1.2 — Storage buckets

One bucket: **`avatars`**, `public = true` (sql/65).

- **Read:** public — by design, so a pharmacy/admin can render a locum's optional photo. Acceptable per the handoff's "a public avatar may be acceptable — decide and document." **Decision to record:** professional headshots the user opted to upload; nothing sensitive. → keep public.
- **Write / update / delete:** owner-scoped — first path segment must equal `auth.uid()`. A user can only write their own folder. ✓
- **Path guessability:** paths are `<uuid>/photo.<ext>`. UUIDs aren't sequential, so URL-guessing another user's object is impractical. ✓ (No need to switch to UUID names — already effectively UUID-scoped.)
- **⚠ Confirm live (bucket-level, not in the migration):** the handoff wants uploads "constrained by content-type and size." The RLS policy constrains the *path* but not MIME type or file size. Check in Supabase → Storage → avatars → settings that an allowed-MIME-types list and a max file size are set. If unset, an authenticated user could upload a large or non-image file into their own folder. Low severity (own folder, public-read image bucket), but it's the one open item here.

---

## 4. Task 1.3 — Public-asset sweep

Cloudflare Pages serves the **entire repo** (no build step), so every tracked file is a candidate for public download. The only gate is `functions/_middleware.js`, which 404s these paths: prefixes `/sql/`, `/workers/`, `/.git/`, `/media/911/`; extensions `.md .sql .toml .lock .zip`; and internal-doc prefixes `/c-direct-actions- /c-direct-audit- /c-direct-scenarios- /phase-test-report /rapport-test-`. Default is allow.

**FINDING (decide) — `/media/911/` is still in the repo and still ships.** It contains your redesign source: `c-direct-refonte-handoff.html` (845 KB), `acces-2026-08-15-pre-refonte.html`, two `.md` specs, and `/promo` images. Runtime it is 404'd by the `/media/911/` prefix — but the handoff's explicit standard is "removed from the repo **or excluded from build output**, not just unlinked." Middleware blocking is exactly the "just unlinked" case: the files still deploy to Cloudflare's edge and are one middleware edit away from public again. The two `.html` files are protected **only** by that single prefix line (`.html` is not extension-blocked). This is the same class as the original `/media/911/` incident.

### ✅ RESOLVED — 19 August 2026 (Robert chose Option 1)

Fixed in commit **`c4674cc`** (+ workflow in `12e66d3`). Three changes, one commit:

1. **`media/911/` → `.internal/redesign-911/`** — a dot-prefixed folder. Cloudflare Pages **never deploys dot-folders**, so the redesign source stays in the repo but can no longer ship, *independently of the middleware*. This is the "excluded from build output" standard the handoff demands, not the weaker "unlinked".
   **Evidence this mechanism is real on THIS deployment:** the repo's own `_redirects` documents Robert's test of 2026-08-04 — `.well-known/assetlinks.json` was invisible in production ("200 but content = homepage") precisely because Pages skips dot-folders. Proven here, not assumed.
2. **`_middleware.js`** — the `/media/911/` rule became `/.internal/` (defence in depth: blocked at runtime *and* never deployed).
3. **CI asset guard** — `.github/scripts/asset-guard.mjs` + workflow. It parses the block rules out of `_middleware.js` (so guard and runtime can never drift), then fails the build if any *deployable* file matching a sensitive pattern (`*handoff*`, `.md`, `.sql`, `.env*`, `.zip`, internal-doc prefixes) is not covered by a rule. Dot-folders are correctly treated as non-deployable.

**Verification performed (not assumed):**

| Check | Result |
|---|---|
| Guard passes on the real tree | ✅ 214 deployable files, 0 unprotected |
| Guard actually *fails* on a regression (planted `test-handoff-should-fail.html`) | ✅ exit 1, file named |
| `_middleware.js` still parses (`node --check`) | ✅ no syntax error |
| GitHub Actions run #1 | ✅ completed successfully, 17s |
| Live: `/.internal/redesign-911/c-direct-refonte-handoff.html` | ✅ "Not found" (middleware 404) |
| Live: old `/media/911/c-direct-refonte-handoff.html` | ✅ no longer serves the document |
| Live: homepage renders normally after middleware edit | ✅ no breakage |

Note: the old path now falls through to the homepage rather than a hard 404, because the `/media/911/` rule was removed and the file no longer exists. That soft-404 fallback is pre-existing Pages behaviour, unchanged by this commit. It also independently confirms the new middleware is live (the old rule would have produced a plain-text 404).

**Deliberately NOT touched:** `sql/90`, `workers/c-direct-payments/src/index.js` (both had uncommitted local edits — verified byte-identical to origin, so nothing was at risk), `_redirects`, and all page HTML/CSS.

**Undo command** (reverts all three changes, keeps history):

```
cd "/Users/hello/Desktop/Projet 1" && git revert --no-edit c4674cc && git push
```

**OK (blocked by prefix, but prefix-dependent):** `C-Direct-audit-strategie-2026-07-29.pdf`, `C-Direct-scenarios-2026-07-29.xlsx`, `PHASE-TEST-REPORT.pdf` at root. Note `.pdf`/`.xlsx` are not extension-blocked, so any *new* internal PDF not matching a listed prefix would leak. The Phase 3 CI build-output check is the durable fix.

**Confirmed gone:** no `.env`, key, or credential files anywhere in the tree.

---

## 5. Task 1.4 — Secret hygiene (full git history, 423 commits)

Scanned all 423 commits (`git log -p --all`) for: Supabase JWT/`sb_secret_`, Stripe `sk_live_`/`sk_test_`/`whsec_`, Twilio `AC…`/`SK…`, Resend `re_…`, private-key blocks.

- **No key material ever committed.** Every hit was an environment-variable *name* (`env.SUPABASE_SERVICE_ROLE_KEY`) or a doc comment — no values.
- **No JWTs** (`eyJ…`) in history.
- **No `.env`/secret/key/pem** files tracked.
- **service_role** appears only inside `workers/` and `functions/` server code, referenced by env name — **never a literal, never in client JS.**
- The only client-exposed key is `sb_publishable_…` in `supabase-config.js` — the anon publishable key, public by design.

**PASS.** No rotation required on the basis of a committed leak. (gitleaks-in-CI is a Phase 2/D wiring item, deferred until after this gate.)

---

## 6. Notes on the three anon grants (all intentional, low risk)

- `meteo_cache` — anon SELECT/INSERT/UPDATE + `USING(true)`. Weather cache for the "Trajet" feature. No PII. The UPDATE policy is bounded ("maj bornee"). Residual: an anon can write cache rows (mild bloat/poisoning, not a data leak). Acceptable; note for the Phase 5 minimization pass.
- `frais_plateforme()` — anon EXECUTE. Returns the platform fee ($39). Public config, not sensitive.
- `reglages_paiement()` — anon EXECUTE. Returns payment settings (Interac on/off). Public config, not sensitive.

The empirical run's `protected_rpcs` list re-confirms these behave as intended and that `get_contrats_ouverts` / `get_contrat_fiche` / `aa_horaire_libre` reject anon (the sql/77 fix).

---

## 7. What I need from you to finish the empirical layer

The static layer is done. To run the adversarial matrix against live data (the half the handoff insists on), I need:

1. **Four test users on the LIVE project** — Locum A, Locum B, Pharmacy P, Pharmacy Q — each with a little owned data (a profile, an availability/contract, a message). Give me their emails + passwords (throwaway is fine; delete after).
2. **A way for the script to reach Supabase.** Either (a) you run `node rls-adversarial-audit.mjs` yourself from your machine after filling `audit-config.json` — I'll give you the exact steps — or (b) we run it through the browser tools against the live origin.
3. **Run `list_public_tables.sql` once** in Supabase → SQL Editor first (so the list is authoritative from the live schema).

Then the matrix cells flip from PENDING to PASS/FAIL and Phase 1 is truly closed.

---

## 8. Deliverables produced (in my working folder, not yet in the repo)

- `rls-adversarial-audit.mjs` — the runnable test suite (no dependencies; builds the table list from the live schema).
- `list_public_tables.sql` — companion helper (service_role-only) for authoritative enumeration.
- `audit-config.example.json` — template for the four test users and target rows.
- `PHASE1-RESULTATS.md` — this file.

**Why not in the repo yet:** the script carries auth logic and the repo is publicly served. Before it lands, its directory must be added to `_middleware.js`'s block list (add `/security/` to `PREFIXES_BLOQUES`) — a perimeter change that belongs to Phase 3, after this gate. I'll land the script + that one-line block together on your go-ahead.

---

## 9. ⛔ STOP — Gate 1

Per the plan, I stop here for your review before any Block 2 (auto-accept) work. Decisions I need from you:

1. **`/media/911/`** — move (recommended), remove, or keep-as-is? (§4)
2. **Empirical run** — provide the four test users + choose run path (a) or (b)? (§7)
3. **Avatar bucket** — confirm MIME/size limits are set in the dashboard, or tell me to leave it. (§3)

Nothing else proceeds until you say so.
