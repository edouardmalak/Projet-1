# C-Direct — Briefing: where the payment work stands

**Date: 18 August 2026.** Hand this to Claude at the start of a session so it
knows the state of play without re-deriving it. Written after a working session
that flushed the test data, made the platform fee configurable, ran the first
real-money payment, and fixed three bugs that run exposed.

---

## 1. Read these first, in this order

| File | Why |
|---|---|
| `CLAUDE.md` | Project rules. Surgical edits, auto-sync, bilingual, both-sites rule. Non-negotiable. |
| The `c-direct-payments` skill | The locked payment architecture and its three constraints. **Consult before writing any Stripe code or proposing any payment provider.** |
| `PLAN-PAIEMENT-INSTANTANE.md` | The proposed next build. Nothing in it exists yet. |
| `A-FAIRE-CONSOLIDE.md` | Open actions, including three bugs marked corrected today. |
| `ETAT-RAIL-PAIEMENT.md` | Payment rail status. Header updated today. |

---

## 2. The architecture in one paragraph

C-Direct matches Quebec pharmacies with independent locum pharmacists. A flat
fee per shift. **Gross shift wages must never enter a C-Direct account** — that
is a legal constraint, not a preference: holding worker funds risks
classification as an *agence de placement de personnel* under Quebec law, plus
FINTRAC MSB registration, an AMF licence and RPAA registration. The mechanism
that avoids this: the pharmacy stores a card at onboarding; at T-24h an
uncaptured PaymentIntent is created as a **direct charge on the locum's Stripe
connected account**, so money settles straight to the locum and only the
application fee reaches C-Direct. Cancel it and the pharmacy pays nothing;
capture it and the locum is paid. The authorization is the escrow, and nothing
sits anywhere — not even at Stripe.

---

## 3. What changed on 18 August 2026

**Restore point before anything:** git tag `restore-2026-08-18-avant-flush-tests`.
Note it covers **files only, not database rows**.

### a. Database flushed to a launch-clean state — `sql/81`

Deleted: 97 contracts, 41 candidatures, 5 guarantees, 19 journal rows, 5
invoices, 813 logged SMS, 175 queued SMS, plus matching queue, evaluations,
threads, messages, appointments and Stripe event log. Reference counter reset,
so the next contract is **CD-100001**.

Deliberately kept: all 5 profiles, `stripe_comptes` (the pharmacy's card and the
locum's connected account — deleting these would have broken the test), all 46
`disponibilites` rows (the locum calendar is off-limits by standing rule), and
`favoris_pharmaciens`.

### b. Platform fee is now a database setting — `sql/82`

Was hardcoded `39` in two places. Now `public.parametres_plateforme`, written
only through `modifier_frais_plateforme()` (admin-only, guard above $100), read
by anyone through `frais_plateforme()`. New admin screen **Administration →
Frais de plateforme**, with change history. The Worker reads it on every
authorization via `fraisCdirect(env)`, falling back to the 39 constant only if
the read fails.

**It is currently set to 0** for testing. Robert knows; he is reworking his fee
structure and has asked not to be reminded about it.

### c. First real-money run — it worked

Contract **CD-100001**, $0.19/h × 1h, fee $0.

- Cron created the authorization by itself for **exactly 50¢** —
  `pi_3U5mOgDn37SeUr1A3oaGuYiD`, first attempt, no errors.
- Then it was **captured**. Real money moved.
- Connected account `acct_1U5dBvDn37SeUr1A`, `charges_enabled` and
  `payouts_enabled` both true. The Stripe identity blocker is cleared.

Both halves of the state machine are now proven live. The claim in
`ETAT-RAIL-PAIEMENT.md` that no dollar had circulated is obsolete; its header
has been updated.

**Outstanding:** the 50¢ has not been refunded. Robert chose to leave it to
watch it reach his bank account. Expect **$0.19** (not $0.50 — the other $0.31
went to the platform as the application fee, which covered Stripe's charge),
arriving roughly **25–27 August** (Canada's initial settlement is 7 calendar
days, then 3 business days).

### d. Three bugs found by that test, all fixed — `sql/83`

1. **Shift times were read as UTC.** The database runs in UTC and shifts are
   stored as a plain date plus a plain time, so `(date_contrat + heure_debut)
   ::timestamptz` resolved in UTC — an 08:00 Montreal shift was seen as 04:00
   local. Every T-24h deadline and the whole retry ladder was 4 hours out (5 in
   winter), and early-morning shifts could fall outside the window and never be
   authorized. Now uses `at time zone 'America/Toronto'`, which is the
   convention already used in `sql/09`, `sql/28`, `sql/68` and `sql/70` — the
   guarantee functions were the only ones not following it.
2. **The capture safety net fired for shifts that never happened.**
   `lister_garanties_a_capturer` captured whenever `capture_before <= now() + 6h`
   with no condition on the shift. A guarantee on a cancelled shift, or one whose
   timesheet was never submitted, would still charge the card ~7 days later. The
   net is kept — it protects a locum whose pharmacy goes silent — but now
   requires the shift to have actually **ended** and the contract not to be
   cancelled.
3. **The journal lost its `captured` row.** It was logged with
   `ancien_statut = null`, so any `old || '->' || new` concatenation evaluated to
   NULL and the row vanished from readouts — in the table that serves as evidence
   in a card dispute. The RPC now returns the starting status and the Worker
   passes it through.

`lister_garanties_a_capturer` **changed shape** (added `statut`), so the Worker
was redeployed. Live version: **`186d61ba`**.

### e. Wrangler telemetry disabled

`send_metrics = false` in all three `wrangler.toml`, plus globally on Robert's
machine.

---

## 4. Decisions made today that are NOT yet built

Robert decided to change the payment model. **None of this exists in code.** Full
detail in `PLAN-PAIEMENT-INSTANTANE.md`.

- **No Interac for the first months.** Cheque kept as a fallback, with the locum
  confirming receipt to release the hold.
- **Every payment must be instant.** Waiting is not acceptable.
- **The locum must never absorb a fee.** Robert is reworking his fee structure to
  absorb Stripe's 1% instant-payout charge.
- **"Debit" means debit card at checkout** — Visa Debit / Debit Mastercard. These
  run on the card networks, so **the existing Stripe rail already accepts them.
  No work, no new vendor.** This was the key clarification; an earlier reading
  suggested pre-authorized bank debit, which is impossible (see §6).
- **Clock in / clock out.** Clock-out is what triggers funding.
- **Presence proof:** photo plus captured location, **verified then discarded** —
  store only pass/fail plus timestamp, never the image or coordinates. Quebec
  Law 25.
- **If clocked hours differ from the contract**, the amount is recalculated and
  **both parties must approve** before any funding.

### Instant payouts — the constraint that shapes everything

In Canada, Stripe Instant Payouts go **only to a debit card**. Bank accounts are
not eligible here, unlike US/GB/EU/SE/DK/SG/AU. So a locum with only a bank
account can never be paid instantly. Cost is 1% to the platform, minimum
0.60 CAD, maximum 9,999 CAD per payout. Requires "Allow debit cards?" = Yes in
Connect settings, which is dashboard-only.

> **Verify before promising instant publicly:** Stripe does not make new
> connected accounts instant-eligible immediately — there is a ramp based on
> processing volume and account age, and each platform has a daily instant-payout
> ceiling across all accounts. Robert has been told to confirm his ramp with
> Stripe directly.

---

## 5. Three open questions awaiting Robert's answer

Proposed defaults, not yet confirmed:

1. **Pharmacy never approves the amended hours** → 3-hour deadline, then
   auto-capture the *lesser* of contracted or clocked amount and pay instantly.
   Never charge more than already agreed without approval; the difference becomes
   a separate claim.
2. **Locum forgets to clock out** → automatic clock-out at contract end + 2h,
   flagged as automatic, funded at the contract amount.
3. **Locum has no eligible debit card** → block shift acceptance until one is
   registered.

---

## 6. Ruled out — do not re-propose

Read the skill's `references/ruled-out.md` before suggesting any provider.

**VoPay** was explicitly requested by Robert and had to be refused. Its Interac
Money Request settles into VoPay's pooled account with C-Direct as *requester of
record* — C-Direct becomes the payee, violating the core constraint. Its
Payfac-as-a-Service model would make C-Direct the payment facilitator, inheriting
FINTRAC MSB registration, AMF licensing, RPAA registration and a full AML
program. It also does not process credit cards. **Zūm Rails, Paysafe, Nuvei,
Flinks, QuickBooks Payments, ACSS/PAD and every Interac API integration** are
rejected for the same custody reason.

The generalisation worth remembering: **any pull-based bank rail names its payee
in the mandate**, so the mandate cannot be pointed at the locum. Cards are the
only Canadian rail where a platform can orchestrate a payment that settles
directly into a third party's account without ever being the payee.

---

## 7. Traps that cost time today

- **`c-direct-payments` does NOT auto-deploy from GitHub.** Every version in its
  Cloudflare Deployments tab is "Manually deployed / Wrangler". A push to `main`
  leaves the old payment code running. After any edit, Robert must run
  `npx wrangler deploy` from `workers/c-direct-payments`. The other two workers
  (`c-direct-sms`, `c-direct-chat`) *do* auto-deploy. Check per worker.
- **The Cloudflare "Edit code" editor shows the bundled esbuild output**, not the
  repo source. Patching there desyncs the deployment from git. Don't.
- **`git pull` aborts in Robert's folder** whenever Claude creates a new file:
  the file already exists on disk untracked, and git refuses to overwrite it. Use
  `git fetch origin && git reset --hard origin/main` instead. Verify file
  equality first; today all changed files were byte-identical to origin.
- **Stale `.git/index.lock`** can be left behind and blocks the next git command.
  If `rm` fails with "Operation not permitted", request delete permission first.
- **Robert is not a developer.** Give numbered steps, one action per step, and
  **no quotation marks in paths he types** — a dropped closing quote left his
  shell stuck at a `dquote>` prompt today.
- **Supabase SQL editor** shows a "Potential issue detected" confirmation for
  destructive statements; it must be clicked through.

---

## 8. Current live state

| Item | Value |
|---|---|
| Platform fee | **0** (`parametres_plateforme`) |
| Network hourly floor | 120 $/h (temporarily lowered to 0.01 for the test, restored) |
| Payments Worker | `186d61ba` |
| Connected account | `acct_1U5dBvDn37SeUr1A` — charges and payouts enabled |
| Contracts / candidatures / guarantees | 1 each — the CD-100001 test, status `captured` |
| Interac | still enabled in code; the decision to disable it is not implemented |
| Instant payouts | not built |
| Clock in/out | not built |

---

## 9. Suggested next steps

1. Confirm or correct the three defaults in §5.
2. Robert: set "Allow debit cards?" = Yes in Stripe → Settings → Connect →
   Payouts → External accounts, and ask Stripe about the instant-payout ramp.
3. Build in this order, one migration and one commit per phase, with a real test
   between each: Interac off → instant payouts → clock in/out → amendments.
4. Next SQL migration number is **`sql/84`**.
