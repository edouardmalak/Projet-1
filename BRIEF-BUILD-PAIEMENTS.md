# Brief — C-Direct payments build (corrected, 18 August 2026)

**This supersedes `cowork-brief-c-direct-payments.md`.** That draft was written
as a greenfield build. It is not one: phases 1–4 of it already exist, and the
card rail moved real money on 18 August 2026. Following it as written would
rebuild working code and reintroduce Interac, which has just been switched off.

Paste this as the first message in a fresh session with the project folder open.

---

## Mission

**Continue** the C-Direct payment system. Do not rebuild it. Launch: September 2026.

## Mandatory reading, in this order — before any code

1. `CLAUDE.md` — project rules. Surgical edits, bilingual, both-sites rule, auto-sync.
2. The **`c-direct-payments` skill** in full, plus `references/ruled-out.md` and
   `references/stripe-docs.md`. Every architectural decision is already made.
   Do not re-litigate it.
3. The **`surgical-edits` skill** — apply to all existing code.
4. `BRIEFING-CLAUDE-2026-08-18.md` — what changed on 18 August and why.
5. `PLAN-APP-MOBILE.md` — a Flutter app follows this work. It constrains where
   code may live (see Rule 7 below).

**Phase 0 — audit before building.** Inventory what exists in Supabase,
Cloudflare and Stripe. Produce a one-page summary of what exists, what is
reusable, and what conflicts with the locked architecture. **Stop and show
Robert before starting.**

---

## What already EXISTS and must not be rebuilt

Verified in code and against the live database on 18 August 2026.

| Built | Evidence |
|---|---|
| Payment state machine, 7 statuses | `sql/43`, `garanties_paiement` + journal |
| T-24h authorization engine, automatic | cron every 15 min, ran unaided |
| Retry ladder T-18h / SMS T-12h / escalate T-6h | `calculerProchainePhase()` |
| Card cloning per shift (single-use) | `autoriserCandidature()` |
| Gate on `charges_enabled && payouts_enabled` | live GET per attempt |
| Capture, and cancel-on-confirmation | both proven live |
| Stripe Connect onboarding + `refresh_url` | `acct_1U5dBvDn37SeUr1A` active |
| Webhook, signed, 9 events | `/stripe/webhook` |
| Invoice generation | `factures` + PDF in the SMS worker |
| Platform fee as a DB setting | `sql/82`, admin screen |
| Interac on/off switch | `sql/84`, off by default |

**Proof it works:** contract CD-100001, $0.19/h × 1h, fee $0 → authorized for
exactly 50¢ (`pi_3U5mOgDn37SeUr1A3oaGuYiD`) then captured. Both halves of the
state machine are proven with real money, not just written.

---

## Locked decisions — 18 August 2026

1. **No Interac** for the first months. Switched off in `sql/84`. Cheque remains
   as a fallback on agreement, with the locum confirming receipt to release the hold.
2. **"Debit" means debit card at checkout** (Visa Debit / Debit Mastercard).
   These run on the card networks and **the existing Stripe rail already accepts
   them**. No new vendor, no code. VoPay was requested and refused — see Rule 2.
3. **Every payment must be instant.** Waiting is not acceptable.
4. **The locum never absorbs a fee.** Robert is reworking his fee structure to
   absorb Stripe's 1% instant-payout charge.
5. **Clock-out triggers funding.**
6. **Presence proof is a deterrent, not a gate.** Capture photo and location,
   verify, store only pass/fail plus timestamp — never the image or coordinates
   (Quebec Law 25). Show the pharmacy a green/amber signal. **Never block funding
   on it alone**: GPS fails indoors and in rural Quebec, and a pharmacist denied
   pay by a bad fix is the worst failure this product can have.
7. **Hours differing from contract:** locum confirms their own hours at clock-out.
   A *decrease* funds immediately — no pharmacy approval, it is in their favour.
   An *increase* needs pharmacy approval; if silent after **3 hours**, capture the
   **contracted** amount instantly and treat the difference as a separate claim.
   Nobody is ever charged more than they agreed to without saying yes.
8. **Missed clock-out:** automatic at contract end + 2h, flagged as automatic,
   both parties notified, funded at the contracted amount.
9. **No eligible debit card → block shift acceptance**, not signup. Onboarding
   stays deferred until first acceptance.

---

## Hard constraints — violating any of these is a failed build

1. **Gross shift wages never enter a C-Direct account, balance or wallet.**
   Stripe only. No pooled accounts, no escrow, no held funds. This is legal, not
   preference: it risks classification as an *agence de placement de personnel*,
   plus FINTRAC MSB registration, an AMF licence and RPAA registration.
2. **Never propose a payment provider without reading `references/ruled-out.md`.**
   VoPay, Zūm Rails, Paysafe, Nuvei, Flinks, QuickBooks Payments, ACSS/PAD and
   every Interac API integration are rejected. The reason generalises: **any
   pull-based bank rail names its payee in the mandate**, so it cannot be pointed
   at the locum. Cards are the only Canadian rail where a platform can orchestrate
   a payment settling directly to a third party without being the payee.
3. **Never write Stripe code from memory.** Fetch the doc URL mapped in
   `references/stripe-docs.md`. If a doc contradicts the skill, stop and report.
4. **Never collect or store a locum's SIN, ID or bank details.** Stripe hosted
   onboarding only.
5. **Outbound SMS accent-free** (GSM-7). An accent switches segments from 160 to
   70 characters and silently triples Twilio cost.
6. **Every Stripe POST carries an Idempotency-Key** and is gated by the database
   state machine.
7. **All new business logic lives in Supabase RPCs, never in page JavaScript.**
   The codebase has 68 `sb.rpc()` calls across 16 pages and zero duplicated
   client-side calculation. A Flutter app will call these same functions. Logic in
   a `.html` file is logic the app must reimplement, and two copies of payment
   gating drift apart. Presentation in the page is fine; decisions are not.
8. **Copy presents the locum's invoice, never a C-Direct demand.** The stored card
   is *garantie de paiement*, never *mode de paiement*. Never describe C-Direct as
   an agency, staffing service, employer or payroll provider.

---

## Build order — confirmed with Robert

**Phase A — Test foundation. Do this before adding payment code.**
There is no test suite and no CI. Today's three bugs were found by spending real
money. Build: automated tests on every state-machine transition, explicitly
including the two that must never happen — *"j'ai envoyé" must not cancel a hold*,
and *`amount_mismatch` must never cancel* — plus a way to exercise Stripe in
**test mode** rather than against Robert's live card. Note the system currently
runs on **live keys**; do not change them without asking.

**Phase B — Row locking.** `SELECT ... FOR UPDATE SKIP LOCKED` on the guarantee
cycle. The skill mandates it; it exists nowhere today. Overlapping cron runs can
touch the same row. Small change, severe failure mode.

**Phase C — Instant payouts.** Canada allows Instant Payouts **only to a debit
card** — bank accounts are not eligible here. Collect a debit card as the external
account at locum onboarding, check `instant_available.net_available` and that the
external account lists `instant` in `available_payout_methods`, then create the
payout with `method=instant`. 1% to the platform, min 0.60 CAD, max 9,999 CAD.
⚠️ Stripe does **not** make new connected accounts instant-eligible immediately —
there is a ramp on volume and account age, plus a daily platform ceiling. Confirm
with Stripe before this is promised publicly.

**Phase D — Backup card + concurrent-authorization cap.** The retry ladder already
has a "try the second card" rung with no second card behind it. And with Interac
off, every shift now runs the card: twelve shifts a month is ~$17,000 of rolling
authorizations on one credit card, so limits are a real launch blocker.

**Phase E — Clock in/out.** All rules as RPCs (in range, hours differ, amendment
needed, funding allowed). Thin web UI now; Flutter calls the same functions later.
Store pass/fail plus timestamp only.

**Phase F — Amendments + bilateral approval**, per decisions 7 and 8.

**Deferred, agreed:** CI with the accent lint; *Pharmacie de confiance* tier.

**Not yet scheduled:** the public copy rewrite. `index.html`, `faq.html`,
`regles.html`, `pharmacies.html` and `profil.html` still sell Interac — ten
mentions on the homepage alone, including a comparison-table row. The site
currently advertises a rail the app no longer offers. To be done as one bilingual
pass, together with dropping the "0 % commission" line, which is the competitor's
own brand premise. The SMS worker also has 24 Interac mentions in its templates.

---

## Traps that already cost a day

- **`c-direct-payments` does NOT auto-deploy from GitHub.** Every version is
  "Manually deployed / Wrangler". A push leaves the old payment code running.
  Robert must run `npx wrangler deploy` from `workers/c-direct-payments`.
  `c-direct-sms` and `c-direct-chat` *do* auto-deploy. Check per worker.
- **The Cloudflare "Edit code" editor shows the bundled esbuild output**, not
  source. Patching there desyncs the deployment from git.
- **The database runs in UTC** and shifts are stored as date + bare time. Always
  use `at time zone 'America/Toronto'` when comparing to `now()` — the convention
  in `sql/09`, `sql/28`, `sql/68`, `sql/70`. Getting this wrong put every payment
  deadline 4 hours out.
- **`lister_garanties_a_capturer` has a second trigger** — it also fires 6h before
  the hold expires. A test authorization left alone WILL charge the card ~7 days
  later. Close out test holds deliberately.
- **`git pull` aborts** in Robert's folder whenever a new file is created. Use
  `git fetch origin && git reset --hard origin/main` after checking file equality.
- **Robert is not a developer.** Numbered steps, one action per step, and **no
  quotation marks in paths he types** — a dropped closing quote stranded his shell
  at a `dquote>` prompt.
- **Supabase SQL editor** shows a "Potential issue detected" dialog on destructive
  statements that must be clicked through.

---

## Waiting on Robert — no code can do these

- **"Allow debit cards?" → Yes** in Stripe → Settings → Connect → Payouts →
  External accounts. Blocks Phase C.
- **Confirm the instant-payout ramp with Stripe** before promising "always instant".
- **Confirm the "Stripe handles pricing" Connect model** is in effect.
- Fee structure rework to absorb the 1%.

## Current live state

Platform fee **0**. Interac **off**. Hourly floor 120 $/h. Payments Worker
`186d61ba`. Next SQL migration: **`sql/85`**. One contract in the database
(CD-100001, `captured`). Instant payouts, clock in/out and amendments: not built.

## Definition of done per phase

One numbered SQL migration, one commit, real verification in the browser before
moving on — not "it should work". State files touched, what was deliberately not
touched, and the exact undo command. Confirm with Robert at every phase boundary
and before anything that touches live money.
