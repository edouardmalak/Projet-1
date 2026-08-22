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
| 1.1 empirical — **anon layer** | 47 tables + 9 RPCs probed live, no session | **PASS — 0 leaks** (see §2b) |
| 1.1 empirical — cross-user layer | Authenticated locum vs. everyone else's data | **PASS** — 0 leaks (§2e) |
| 1.1 empirical — pharmacy↔pharmacy | Pharmacy P ↔ Pharmacy Q | **PENDING** — 3 accounts still unconfirmed |
| 1.2 | Storage bucket audit | **1 MEDIUM finding — fix identified** (§3) |
| 1.3 | Public-asset sweep (/media/911/ class) | **FAIL → FIXED & VERIFIED 19 Aug** (§4) |
| 1.4 | Secret hygiene, full git history (423 commits) | **PASS** (§5) |

No leak of the sql/73 class (anon-executable SECURITY DEFINER RPC) survives in the migrations: sql/77 revoked all three. That was the highest-severity historical finding and it is closed in code — the empirical run confirms it live.

---

## 2. Task 1.1 — Table RLS + policy inventory (static)

**Table list source:** the 93 committed migrations (`sql/*.sql`) — **and verified against the live schema on 19 Aug 2026** (§2c). **47 base tables**, **all with `ENABLE ROW LEVEL SECURITY`**. Zero tables created without RLS.

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

## 2b. Task 1.1 — EMPIRICAL anon layer (run live, 19 Aug 2026)

Run against production (`fenlujjozanerbzyypjt.supabase.co`) with **no session**, using only the public publishable key — i.e. exactly what any stranger on the internet can do. Read-only; nothing was written. This is the layer that needs no test accounts, and it covers the exact class of both prior incidents.

**Result: 0 leaks / 47 tables.**

| Outcome | Count | Detail |
|---|---|---|
| DENIED (401, fail-closed) | 44 | Query aborts on `permission denied for function est_admin` — anon can't even evaluate the policy |
| Returned data to anon | **1** | `meteo_cache` only — the weather cache, public by design, no PII |
| 200 but 0 rows (RLS filtered) | 2 | `fsa_centroides` (policy = `auth.role() = 'authenticated'`), `articles` → see observation below |

The API schema root (`/rest/v1/`) also returns **401** to anon — the OpenAPI document is not exposed, so an attacker cannot enumerate the table list.

### RPC probes — historical leaks re-tested live

| Function | Prior incident | Anon result | Verdict |
|---|---|---|---|
| `get_contrats_ouverts` | sql/73 leak | 401 permission denied | ✅ CLOSED |
| `get_contrat_fiche(p_ref)` | sql/73 leak | 401 permission denied | ✅ CLOSED |
| `aa_horaire_libre` | sql/70 gap | 401 permission denied | ✅ CLOSED |
| `get_stats_pharmacien` | sql/63 leak | 401 permission denied | ✅ CLOSED |
| `get_note_profil` | sql/63 leak | 401 permission denied | ✅ CLOSED |
| `supprimer_mon_compte` | destructive | 401 permission denied | ✅ DENIED |
| `frais_plateforme` | anon by design | 200 → `0` | ⚠ see finding |
| `reglages_paiement` | anon by design | 200 → `{frais_cdirect_dollars: 0, interac_actif: false}` | ⚠ see finding |

**The sql/63 and sql/73 fixes are confirmed effective in production, not just in the migration files.** That was the single highest-severity item in this codebase's history.

### 🔴 FINDING P0 (business, not security) — platform fee is 0 in production

`frais_plateforme()` returns **0** and `reglages_paiement()` confirms `frais_cdirect_dollars: 0` on the **live** database right now.

`sql/82` seeds the row at `values (1, 0)` with `on conflict do nothing`, so 0 is the seeded default and it has never been raised. Combined with the 18 Aug live payment test, the fee has simply never been set to 39.

**Impact: if the site launched today, every shift would be billed $0 in platform fees.** This is not an RLS issue and it does not block Phase 1 — but it is launch-blocking and it is now confirmed with production evidence rather than inference. It belongs on the Bloc 5 pre-launch checklist as a verified-with-evidence item.

Fix is a value change in the admin settings (or one UPDATE on `parametres_plateforme`), not code. **Not actioned — payment-adjacent and outside Phase 1 scope.**

### Observation — the dispensaire is invisible to logged-out visitors

`articles` policy is `publie = true or public.est_admin()`. Because anon lacks EXECUTE on `est_admin()`, the whole predicate errors and anon gets 401 — so **published articles are unreadable by logged-out visitors and search engines**, even though `publie = true` reads as intended-public.

Fail-closed, so not a security problem. But if the dispensaire is meant to be a public/SEO surface, it does not currently work that way. This interacts directly with the Bloc 5 item "décision dispensaire : visible ou caché au lancement". Flagged for that decision — **not changed** (the fix is a policy restructure, not granting anon rights to `est_admin`, and it is a product call).

### Still pending in this layer

Cross-user tests (Locum A reading Locum B, Pharmacy P reading Pharmacy Q, forbidden UPDATE/DELETE) require the four test accounts.

---

## 2e. Task 1.1 — EMPIRICAL cross-user layer (run live, 21 Aug 2026) — **PASS**

Run with a **real authenticated session** as `edouardmalak+locuma@gmail.com`
(uid `9751e373-…0607092`), a freshly signed-up locum **pending admin approval** — i.e. the
easiest attacker to be, since anyone can self-serve an account in two minutes. Robert
performed the login; the tests ran inside the session his login created.

At the time of the test the project had **9 real users** in `auth.users` (admin + 4 new test
accounts + 4 older test accounts).

### Results

| # | Attempt | Expected | Observed | Verdict |
|---|---|---|---|---|
| 1 | Read **own** profile (control) | ALLOWED | 200, 1 row | ✅ PASS |
| 2 | Read the **admin's** profile by uid (Edouard Malak) | DENIED | 200, **0 rows** | ✅ PASS |
| 3 | **Unfiltered `SELECT * FROM profiles LIMIT 200`** | own row only | 200, **1 row total, 0 foreign** | ✅ **PASS** |
| 4 | `contrats` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 5 | `candidatures` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 6 | `messages` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 7 | `factures` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 8 | `garanties_paiement` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 9 | `stripe_comptes` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 10 | `sms_log` unfiltered | no foreign rows | 200, 0 rows | ✅ PASS |
| 11 | **UPDATE another user's profile row** (`nom` → `AUDIT-TEST-SHOULD-FAIL` on locumB) | DENIED | 200, **0 rows changed** | ✅ **PASS** |

**No data was modified.** Test 11 returned zero affected rows; the target row was left untouched.

### Why tests 3 and 11 are the decisive ones

Tests 4–10 returned zero rows, which is *consistent* with RLS working — but those tables may
also be sparsely populated after the test-data flush, so on their own they do not distinguish
"RLS blocked it" from "nothing there to see". They are supporting evidence, not proof.

Tests 3 and 11 are proof, because they run against a table **known to be populated**:

- **Test 3** — `profiles` certainly holds 9 rows (one per `auth.users` entry). An unfiltered
  select returned exactly **1**: the caller's own. Every other user's name, email, phone and
  OPQ licence was filtered out by the database, not by the interface. **This is the xPayrience
  table** — the equivalent of the 414,000-record customer table that leaked — and it is
  correctly isolated.
- **Test 11** — the target row (locumB's profile) definitely exists, so "0 rows changed" can
  only mean the write policy rejected it. Read isolation *and* write isolation are both
  demonstrated on live data.

### What this does and does not establish

**Established:** an authenticated, unvetted account cannot read or write any other user's
row, including the administrator's. Combined with §2b (anonymous access, 47/47 tables, 0
leaks) and §2c (live schema fully covered), the two realistic mass-dump paths — no session,
and a self-serve session — are both closed.

**Not yet established:** pharmacy-to-pharmacy isolation (Pharmacy P reading Pharmacy Q's
contracts, invoices and relations). Those two accounts remain unconfirmed. Static analysis
shows the same `auth.uid()`-scoped predicates that just proved out empirically for the locum
side, so the expectation is a pass — but it is untested. Complete it when the accounts work.

### Inconclusive — retest when shift data exists

`get_contrats_ouverts()` called by the **unapproved** locum returned **200 with 0 rows** — it
executed rather than refusing (a refusal would be 401). With no open shifts in the database,
this cannot distinguish "approval gates the read" from "there was nothing to return".

Code review (§ below) shows `est_approuve()` is checked only in the `contrats_insert` and
`candidatures_insert` policies — never on reads, and not inside `get_contrats_ouverts()`. So
the likely behaviour is that any signed-up account can browse the open-shift market before
vetting. That is plausibly deliberate (showing value pre-approval), and the sensitive part is
already protected: the function returns city, postal code and rate but **not** pharmacy name,
address or id, so the "pharmacy identity hidden pre-confirmation" product rule is enforced at
the data layer. **Retest once at least one shift is published, then confirm the intent.**

---

## 2d. 🔴 FINDING P0 — password reset is broken on the live domain

Discovered 21 Aug 2026 while trying to obtain a test session. **Not found by code review — the code is correct. It only surfaced by actually running the flow.**

### Symptom
Requesting a password reset from `cdirect.quebec` sends the email, but clicking the link returns the user to the site homepage with no reset form. The account stays locked out.

### Root cause
Supabase → Authentication → URL Configuration:

- **Site URL:** `https://c-direct.ca`
- **Redirect URL allowlist:** `https://projet-1-1yi.pages.dev/**`, `https://c-direct.ca/**`, `https://www.c-direct.ca/**`

**`cdirect.quebec` is absent from the allowlist** — yet that is the domain users actually land on.

`acces.html` correctly calls:

```js
sb.auth.resetPasswordForEmail(c, { redirectTo: location.origin + location.pathname + '?mode=reset' })
```

which on the live domain evaluates to `https://cdirect.quebec/acces?mode=reset`. Supabase checks that against the allowlist, does not find it, **silently discards it**, and falls back to the Site URL — the homepage. The recovery token arrives in the fragment of a page that has no `PASSWORD_RECOVERY` handler (`acces.html` has one; `index.html` does not), so nothing happens.

The application code needs no change. `acces.html` builds the right URL, and line 806 handles the recovery event correctly.

### Impact
**Any real user who forgets their password cannot recover their account.** Launch-blocking. The same allowlist governs every auth redirect — email confirmation, magic links, OAuth callbacks — so anything relying on `redirectTo` from `cdirect.quebec` is affected.

### Fix
Add to the Redirect URL allowlist:

```
https://cdirect.quebec/**
https://www.cdirect.quebec/**
```

### ✅ RESOLVED — 21 August 2026

Robert added `https://cdirect.quebec/**` to the Redirect URL allowlist (4 entries total; the
`www.` variant was judged unnecessary since traffic does not use it). **Verified end to end:**
a fresh reset email was requested, the link opened the real "Nouveau mot de passe" page, the
password was set, and the session landed on `/attente` as an authenticated pending locum.

Note during verification: the first retry returned `otp_expired` because an **older** email
from before the fix was clicked. Recovery links are single-use and time-limited — always use
the newest message. Worth remembering if a real user ever reports the same symptom.

The unblocked login is what made the cross-user audit in §2e possible.

### Underlying inconsistency to settle
The Site URL is `c-direct.ca` but live traffic resolves to `cdirect.quebec`. Because Site URL is the fallback for *every* auth email, it should be whichever domain users are actually meant to be on. Decide the canonical domain before launch and align Site URL, the allowlist, and the redirect between the two domains.

### Why the cross-user test is blocked
The remaining matrix cells (Locum A ↔ Locum B, Pharmacy P ↔ Pharmacy Q, forbidden UPDATE/DELETE) need authenticated sessions. Four test accounts were created, but:

- `locumA` — confirmed, but the password is unknown and reset is broken by the above
- `locumB`, `pharmP`, `pharmQ` — created, confirmation emails sent but never opened, so sign-in is refused

Static analysis shows every relevant policy is correctly owner-scoped on `auth.uid()` (§2), and the anon layer passes completely (§2b). What remains unproven is the *behaviour* of those policies against live data. **Resume once the auth flow is fixed.**

---

## 2c. Live-schema verification — no shadow tables (19 Aug 2026)

The handoff requires the table list to come from the running database, never from memory or docs, so a table created outside the migration files cannot be silently skipped. Robert ran a `pg_class` enumeration against production and the output was diffed against the tested list:

| Check | Result |
|---|---|
| Tables in live `public` schema | 47 |
| Tables covered by the anon sweep | 47 |
| In live but never tested (**coverage gap**) | **0** |
| Tested but absent from live (stale) | **0** |

**Exact match.** Two conclusions:

1. **The anon sweep in §2b covered 100% of the live schema**, not merely 100% of what the migrations describe. The "0 leaks" result is therefore complete, not partial.
2. **No shadow tables exist.** Every table in production was created through a committed, reviewable migration — nothing was added by hand in the dashboard. This matters beyond Phase 1: it means the Phase 2 migration gate (RLS + deny-by-default in the same migration, CI grep on `TO anon`) is sufficient to govern the whole schema. If hand-made tables existed, that gate would have blind spots.

This also removes the need for the `list_public_tables()` helper — a plain read-only query in the SQL Editor did the job without adding a new SECURITY DEFINER function to the database. The helper file remains in `.internal/security/` unused; the standing enumeration method is the query, which is strictly less attack surface.

---

## 3. Task 1.2 — Storage buckets

One bucket: **`avatars`**, `public = true` (sql/65).

- **Read:** public — by design, so a pharmacy/admin can render a locum's optional photo. Acceptable per the handoff's "a public avatar may be acceptable — decide and document." **Decision to record:** professional headshots the user opted to upload; nothing sensitive. → keep public.
- **Write / update / delete:** owner-scoped — first path segment must equal `auth.uid()`. A user can only write their own folder. ✓
- **Path guessability:** paths are `<uuid>/photo.<ext>`. UUIDs aren't sequential, so URL-guessing another user's object is impractical. ✓ (No need to switch to UUID names — already effectively UUID-scoped.)
### 🟠 FINDING (Medium) — upload validation is client-side only

**Confirmed live 19 Aug 2026** (dashboard): bucket `avatars` has **File size limit: Unset (50 MB)** and **Allowed MIME types: Any**. Policies: 4 (matches sql/65).

The app's protections all run in the browser and are trivially bypassable:

| Control | Where | Bypassable? |
|---|---|---|
| `accept="image/png,image/jpeg,image/webp"` | `profil.html:149` — file-picker hint | Yes — drag-drop, DevTools, or direct API call |
| `if (f.size > 2*1024*1024)` reject | `profil.html` — JS check | Yes — client-side only |
| `contentType: f.type` | `profil.html:361` | Attacker-controlled by definition |
| Path must start with own uid | RLS policy (sql/65) | **No** — genuine server-side control ✓ |

So any authenticated user can upload **any file type, up to 50 MB, with a content type of their choosing**, into a **public-read** bucket — and an unlimited number of files, since the policy pins only the first path segment (`<uid>/…`), not the filename `photo.<ext>` the app happens to use.

**Impact:** not a confidentiality breach (no cross-user read is possible). The risks are (a) hosting malware or phishing pages on infrastructure associated with C-Direct, (b) stored XSS on the storage origin via SVG-with-script or `text/html` — a different origin from `cdirect.quebec`, so app sessions are not directly reachable, but the brand and the origin are, and (c) uncapped storage cost from unlimited 50 MB writes.

This is precisely handoff **Task 2.3**: "validate content-type server-side, cap size, never serve user uploads from a path that allows HTML execution."

**Fix (dashboard, no code):** set file size limit to **2 MB** and allowed MIME types to `image/png,image/jpeg,image/webp`.

- 2 MB, not 5 MB as first suggested — it matches the limit `profil.html` already promises the user, so the server enforces the UI's own contract. (An earlier 5 MB suggestion was made before reading the upload code; it would have allowed files the UI claims to reject.)
- **SVG deliberately excluded.** `image/svg+xml` is an image format that can carry executable script — the one image type that is dangerous in a public bucket.
- Restricting to these three types also closes the "path that allows HTML execution" bullet, since HTML can no longer be stored at all.

Existing avatars are unaffected; the constraint applies to future uploads. **Status: awaiting Robert's dashboard change.**

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

## 9. ⛔ STOP — Gate 1 — status at pause (21 Aug 2026)

Robert paused Phase 1 here. Block 2 (auto-accept) has NOT started and does not start until the items below are settled.

### Closed during this gate

| Item | Outcome |
|---|---|
| `/media/911/` internal docs shipping publicly | ✅ Fixed — moved to `.internal/`, middleware updated, CI guard added (§4) |
| Live-schema drift check | ✅ 47/47 exact match, no shadow tables (§2c) |
| Anonymous access, every table + RPC | ✅ 0 leaks (§2b) |
| Secret scan, 423 commits | ✅ Clean (§5) |

### Open — action required

| # | Item | Owner | Severity |
|---|---|---|---|
| 1 | **Platform fee = 0 in production.** Every shift would bill $0. Set to 39 before launch. | Robert (payment-adjacent, out of audit scope) | 🔴 Launch-blocking |
| 2 | ~~Password reset broken on `cdirect.quebec`~~ | — | ✅ **FIXED & VERIFIED 21 Aug** (§2d) |
| 3 | **Canonical domain** — `c-direct.ca` vs `cdirect.quebec`; align Site URL + allowlist (§2d) | Robert (decision) | 🟠 |
| 4 | **Avatar bucket** — run `sql/91` (drafted, not yet applied): removes anon listing, adds 2 MB + 3 image types (§3) | Claude, on Robert's go-ahead | 🟠 Medium |
| 5 | **Cross-user matrix** — locum side ✅ PASS (§2e). Pharmacy↔pharmacy still pending: confirm the 3 remaining test accounts' emails | Robert (click 3 links) | 🟡 |
| 6 | **Dispensaire invisible** to logged-out visitors and search engines — product decision (§2b) | Robert (decision) | 🟡 |

### To resume

Once #2 is fixed: log in as each of the four test accounts in a **normal** (non-Incognito) browser window, and the cross-user matrix can be completed in minutes. Then Phase 1 closes and Gate 1 can be signed off.

**Note on tooling:** Chrome's Incognito windows are sealed from the automation tools — a session created there is invisible. Test logins must happen in a normal window.
