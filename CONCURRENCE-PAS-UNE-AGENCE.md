# C-Direct — Pas une agence : pricing, share link, Google sync (written 2026-08-16)

Three items came out of the competitor analysis of **Pas une agence** (pasuneagence.com). The analysis itself was only ever delivered in chat and was lost when the session ended — this file exists so that doesn't happen twice.

Legend: 🧑 = only you can do this (an account, real money, a decision). 🤖 = I can do it once you say go.

**Not duplicated here.** The Google Calendar item also appears in `A-FAIRE-CONSOLIDE.md` § 3 ("Built, just needs a switch flipped") and `PRELANCEMENT.md` § *Google Agenda (optionnel)* — both hold the same 4-step summary. This file is the long version of that walkthrough; the other two stay as they are. If you change the plan, change it here and let those two point at this file.

**Privacy note.** Cloudflare Pages serves every committed file, but `functions/_middleware.js` returns 404 for `.md`, so this document is not publicly downloadable. Keep it that way — it names the competitor and our pricing intentions.

---

## Who they are (the short version)

Run by Jean-Simon Collard, WordPress/WooCommerce, French-only, live since roughly September 2024. Public claims: 382 pharmacists, 130 ATPs, 116 "gold" pharmacies — but their own paid-plan bullet says "200+ pharmaciens remplaçants", so the genuinely active pool is likely nearer 200. BeLocum is the other competitor and is handled in the `c-direct-payments` skill (they take roughly a $20/h spread).

**Their exposed flank, in their own words:** their terms and conditions state that if a pharmacy doesn't pay, it's the locum's problem and they offer zero compensation. They are also email-only (no SMS), French-only, and they hand over contact details by email rather than closing the booking in-app.

**One positioning consequence worth acting on separately:** the C-Direct homepage currently leads with "0 % commission", which is the entire premise of *their brand name*. That's fighting on their turf using their slogan. Guaranteed payment is the thing they've disclaimed in writing and we've built — that's the line to lead with. Not part of the three items below; noted so it doesn't get lost again.

---

## 1. Pricing vs their Gold plan — 🧑 OPEN, leaning $195

### The facts

| | Pas une agence | C-Direct today |
|---|---|---|
| Locums pay | free | free |
| Pharmacies pay | **$199.99/month** flat (Gold) | **$39/shift**, uncapped |
| Job poster (permanent roles) | $449.99 incl. 3 months | not offered |

**Break-even: 5.13 shifts/month** ($199.99 ÷ $39). Below that C-Direct is dramatically cheaper. Above it we get more expensive fast — at 10 shifts/month we're roughly 2× their price, at 20 shifts nearly 4×.

### The two capping options, side by side

| Shifts booked in a month | Theirs | C-Direct uncapped (today) | **Option A — $195** (five shifts, rest free) | **Option B — $199** (hard cap) |
|---|---|---|---|---|
| 1 | $199.99 | $39 | $39 | $39 |
| 3 | $199.99 | $117 | $117 | $117 |
| 5 | $199.99 | $195 | $195 | $195 |
| **6** | $199.99 | $234 | **$195** | **$199** |
| 10 | $199.99 | $390 | $195 | $199 |
| 20 | $199.99 | $780 | $195 | $199 |
| **Annual ceiling** | **$2,399.88** | unbounded | **$2,340** | **$2,388** |

Both options undercut them at every single volume. The whole difference between A and B is **$4/month per capped pharmacy** ($48/year) — and it only applies to pharmacies that book six or more shifts in a month.

**Option A — $195, "five shifts a month, the rest are free." ← LEADING OPTION (2026-08-16, not final)**
Clean sentence a pharmacist can repeat to another pharmacist without checking a table. The cap is a consequence of the rule rather than a number we invented. Undercuts them by $4.99/month.

**Option B — $199, "never more than $199 a month."**
Mirrors their price point exactly, which makes the comparison instant — but it also lands $0.99 under theirs, which reads as a deliberate needle rather than a fair price, and invites them to answer with $189. The sixth shift costs $4 and everything after is free, which is harder to explain than A.

**Robert's reasoning for leaning A (2026-08-16):** the $4/month difference is noise. $199 against their $199.99 reads as a needle and invites a $189 reply; "five shifts then free" reads as a policy. **Recorded as the leading option, not locked.**

### Before you lock either one

1. **The cap changes the price mid-month.** This is the thing that actually decides whether to cap at all — worked out in full in section 2 below. Short version: it's buildable and not legally awkward, provided the fee is frozen when the booking is made.
2. **Per what, exactly?** Per pharmacy, per *calendar* month, presumably — but a pharmacy group with five branches will ask whether the cap is per branch or per group. Answer it before they ask.
3. **Free shifts aren't free to us.** Each one still runs the T-24h card authorization (that's $0 at Stripe unless captured) and still carries the chargeback and processing exposure we already absorb on Express accounts. Low, not zero.
4. **Their $449.99 job poster has no C-Direct equivalent.** Permanent-position postings are a separate product decision, not part of this cap.

**Status: open, leaning A.** Nothing is coded, nothing is published, no number is committed.

---

## 2. What the cap actually requires — the mid-month price change

Because the $39 is baked into the all-in figure the pharmacy sees, capping it means the booking-screen price has to change partway through a month. Here is what that concretely touches. I read the code rather than reasoning from the architecture doc.

### Where the all-in price is computed today

Three places, and the fee is a hardcoded constant in two of them:

| Where | What | Note |
|---|---|---|
| `fsa-qc.js` ~line 111 | `window.cdPrixDual(montantLocum)` — `const FRAIS_CDIRECT = 39` | Pure synchronous function. Takes **only a number**. No pharmacy context, no DB access. |
| `espace-pharmacie.html` ~line 924 | `majPrixDual()` calls it live **as the pharmacy types** the shift hours | This is the screen where the price appears |
| `workers/c-direct-payments/src/index.js` line 509 | `FRAIS_CDIRECT_DOLLARS = 39`, used by `calculerMontantCarte()` | The authoritative one — what actually gets authorized |

And in the database, `garanties_paiement` stores `montant_locum_cents` and `montant_carte_cents`. **No column anywhere stores the C-Direct fee.** It only ever exists as the difference between those two numbers:

```js
const fraisApplicationCents = montantCarteCents - montantLocumCents;
```

**One piece of good news falls out of that.** Because `application_fee_amount` is *derived* rather than hardcoded, a $0-fee shift needs no special Stripe handling at all: the application fee simply narrows to the Stripe cost, the locum still nets exactly `montantLocum`, and C-Direct nets $0 — not a negative. The Stripe side of a free shift already works.

### What the pharmacy sees on its 6th booking

The price block updates live while they type. For it to show the capped price, `cdPrixDual` has to know the pharmacy's month-to-date count — which it structurally cannot today, being a synchronous function of one number. The fix is to read the count once on page load and pass the fee in, changing the signature of a helper used in two files. Small, but it is a shared helper, so it's a both-sides change.

Then the number has to agree in three places at once: the live estimate, the **contract** (`contrat.html` states amounts), and the authorization placed at T-24h. If those three disagree, a pharmacy signs one number and gets held for another.

### The ordering trap — why the fee must be frozen at booking

Authorizations fire at T-24h, i.e. in **shift-date order**. Bookings happen in **booking order**. These are not the same sequence: a pharmacy can book the 28th before the 3rd.

So if the count is evaluated when the authorization fires, a shift that was the 3rd booking can turn out to be the 6th shift of the month, and the price quoted at booking was wrong. **The only stable design is to decide the fee when the booking is made and store it** — a new `frais_cdirect_cents` column on the candidature/garantie, plus `calculerMontantCarte(montantLocum, frais)` taking the fee as a parameter instead of reading the constant.

That also fixes the contract problem for free: the contract and the authorization both carry the same frozen number.

### Cancellation — the answer is "never revise, in either direction"

Your scenario: 6 shifts booked, #6 free, then #3 is cancelled. The pharmacy has now consumed 5 shifts and paid $156 instead of $195. Do we claw back the $39?

**No — and not because we're being generous. Because we can't.** Clawing back means raising the amount of an authorization that has already been placed, and **Stripe cannot increase an uncaptured PaymentIntent.** You would have to cancel it and re-authorize at the higher amount, which means a second hold on the pharmacy's card, a fresh `capture_before` window, and a real chance of the card failing at that moment — leaving the locum unguaranteed. That directly violates constraint 3 of the payment architecture (funds secured with no manual action from the owner). And if the shift already settled by Interac, the PaymentIntent was cancelled at $0 and there is simply nothing left to adjust.

**So the rule is: the fee is fixed when the booking is made and never revised afterwards.** The leak is real but bounded — a pharmacy can never cost more than the cap in a month, and exploiting it deliberately means booking real locums and cancelling on them, which runs into the cancellation policy and their own reputation long before it's worth $39.

### The Interac rail — one thing to confirm first

On the card rail the fee rides inside the captured amount, so the cap is a change to a number that's already being computed. On the **Interac rail** the pharmacy pays `montantLocum + $39` directly to the locum and the PaymentIntent is cancelled at $0 on confirmation. Searching the payments Worker and the SQL migrations, **I did not find the mechanism that moves that $39 from the locum to C-Direct** — it may live somewhere I didn't read, or be invoiced separately.

Worth resolving before designing the cap, because it changes the work: if the Interac fee is settled by a separate monthly invoice, the cap on that rail is trivial (invoice `min(39n, 195)`) and this whole mid-month quoting problem exists **only on the card rail**.

### Verdict — not expensive, not legally awkward

You asked me to say plainly if this turned out to be a reason not to cap. **It isn't.**

- **Cost:** one SQL migration (new column), one Worker change, one shared helper signature, one screen, one contract line. Roughly half a day. The one operational wrinkle: `c-direct-payments` is the Worker that does **not** auto-deploy — you'd run `npx wrangler deploy` yourself after pulling.
- **Legally:** freezing the fee at booking means the quoted price, the signed contract and the authorized amount are the same number, which removes the only genuine exposure (being charged something other than what you were quoted). The Quebec *Consumer Protection Act* concern is largely moot here anyway — pharmacies are businesses, not consumers. This is not surcharging: it stays two all-in prices with no fee line item, exactly as the architecture requires.
- **The real cost is comprehension, not code.** Two pharmacies booking the identical shift will see different prices, and dual pricing already asks them to hold two numbers in their head.

**If that last point bothers you, there's a third option that avoids the machinery entirely:** keep every shift at $39 and settle the cap as a **monthly rebate** — refund the excess at month end (Stripe supports refunding an application fee on the card rail). The quoting, the contract and the authorization are all untouched, and you keep the marketing claim. The cost is that pharmacies pay full price up front and get money back later, which is far less persuasive at the moment of booking than seeing $0 on the screen.

---

## 3. Shareable read-only availability link — 🤖 not built, design agreed

### Why it matters

This is **their entire growth loop and we don't have it.** A locum sends a secret URL; the pharmacy opens it and sees their availability **without creating an account**. Zero friction on the side of the market that has all the friction. Every locum who shares a link is doing their customer acquisition for them.

### The mistake we must not copy

**Their link leaks the locum's hourly rate to anyone holding the URL.** Rates spread between pharmacies, pharmacies compare, and the locum loses their negotiating position — and never finds out why. Ours must not show a rate to an unidentified visitor. This is the single hard requirement on this feature.

### Design A — build this now

Read-only public calendar. A visitor sees **availability only**: which days are open, and general area. No hourly rate, no phone number, no email, no contract history. Booking requires signing up — that's the conversion point and the reason the page exists.

- Unguessable token in the URL, revocable by the locum at any time, one toggle to turn sharing off entirely.
- `noindex` plus a middleware rule so the page never lands in a search engine.
- FR and EN in the same change, per the bilingual rule.

### Design C — the later upgrade

The visitor identifies themselves (name and pharmacy, minimum) **before** any rate is displayed. Keeps the link's low friction while making rate disclosure a deliberate, logged act rather than a side effect of holding a URL. Build after A is live and we've seen how the links actually get shared.

### Where this lives — decided 2026-08-16

Per your rule of **2026-08-06**, `disponibilites.html` is off-limits — the pharmacist's Google-synced calendar is not to be touched without your explicit go-ahead. **Decision: we are not spending an exception on it.**

- The share page is a **new file** (e.g. `dispo-partage.html`). It reads availability; it never becomes part of the calendar page.
- The share **toggle** goes in **`parametres.html`**, alongside the other per-account switches. `disponibilites.html` is not modified at all — not one line.
- Trade-off accepted knowingly: the toggle isn't sitting on the screen where the locum is thinking about their availability, so it's less discoverable. If that proves to be a problem after launch, the fix is a link *from* settings, or a revisit of the calendar page as its own decision — not a quiet edit smuggled into this feature.

---

## 4. Google Calendar sync — 🧑 one value away from working

### Status

**The code is already live.** `disponibilites.html` loads Google Identity Services, requests the `calendar.events` scope, and pushes C-Direct availabilities into the pharmacist's Google Calendar. Events created carry the private marker `cdirect=dispo`, so the sync **never touches the user's other appointments**. It is push-only — reading Google is done solely to avoid duplicates and to show the "Dans Google Agenda" pill.

**The only blocker is line 21 of `supabase-config.js`:**

```js
window.CD_GOOGLE_CLIENT_ID = "";
```

While it's empty, the button is inert and shows "Google Agenda : non configuré". The calendar itself works normally without it. Nothing else is missing.

### Read this before you start — the sensitive scope consequences

`calendar.events` is classified by Google as a **sensitive** scope. Three consequences, and the first one is the one that bites:

1. **The 100-user cap is for the lifetime of the project and cannot be reset or raised.** It counts every user who grants access while the app is unverified. You don't get it back by deleting users or making a new client — only a new *project* resets it, and that means redoing all of this. Treat those 100 grants as a budget you're spending.
2. **Every user sees an "unverified app" warning** before the consent screen — "Google hasn't verified this app" — and has to click *Advanced* → *Go to C-Direct*. Pharmacists will ask you about it. Have an answer ready.
3. **Your app name and logo won't display on the consent screen until verification passes.**

**So: submit verification in parallel with launch, not after it.** Verification takes weeks and involves back-and-forth. Requirements are listed in step 13.

### The walkthrough

Do these in order. Where a value is given exactly, paste it exactly.

**1. Sign in with the account that will own this permanently.**
Go to `console.cloud.google.com`. Use `edouardmalak@gmail.com`. This matters later: at step 13 the account that owns this Cloud project must *also* be a verified owner of `c-direct.ca` in Google Search Console. Switching accounts halfway is painful.

**2. Create the project.**
Project picker (top left, beside "Google Cloud") → **New Project** → Name: `C-Direct` → **Create**. Then make sure the picker shows `C-Direct` before continuing — landing in the wrong project is the most common mistake here. Remember: the 100-user cap belongs to *this project*, for its lifetime.

**3. Enable the Calendar API.**
Left menu → **APIs & Services** → **Library** → search `Google Calendar API` → open it → **Enable**. (Not "Google Calendar API v3" or anything Workspace-flavoured — just Google Calendar API.)

**4. Start the Google Auth Platform.**
Left menu → **Google Auth Platform** (this is where the old "OAuth consent screen" now lives). If you see *"Google Auth platform not configured yet"*, click **Get Started** and fill in:
- App name: `C-Direct`
- User support email: `edouardmalak@gmail.com`
- Audience: **External**
- Contact information: `edouardmalak@gmail.com`
- Agree to the policy → **Create**

**5. Fill in Branding.**
Google Auth Platform → **Branding**:
- App home page: `https://c-direct.ca`
- Privacy policy: `https://c-direct.ca/confidentialite.html`
- Terms of service: `https://c-direct.ca/conditions.html`
- Authorized domain: `c-direct.ca`
- Logo: optional, and it won't display until verification passes anyway.

**6. Select the scope — exactly one.**
Google Auth Platform → **Data access** → **Add or remove scopes** → filter for `Calendar` → tick **only**:

```
https://www.googleapis.com/auth/calendar.events
```

Do **not** tick `.../auth/calendar` or `calendar.readonly`. The code requests `calendar.events` and nothing else, and every extra scope makes verification harder to justify. **Update** → **Save**. It will appear under "Your sensitive scopes" — that's expected, not an error.

**7. Add test users.**
Google Auth Platform → **Audience** → under *Test users*, **Add users**. Add `edouardmalak@gmail.com` and any pilot pharmacists. While the app is in *Testing*, only these people can connect, and the list holds 100.

**8. Create the OAuth client.**
Google Auth Platform → **Clients** → **Create client**:
- Application type: **Web application**
- Name: `C-Direct web`
- **Authorized JavaScript origins** — add each with the **Add URI** button:
  - `https://c-direct.ca`
  - `https://www.c-direct.ca`
  - `https://projet-1-1yi.pages.dev`
- **Authorized redirect URIs: leave completely empty.** The code uses the GIS token client, which hands back a token in the browser and never redirects. If you add one here it does nothing.

Then **Create**.

> If the console refuses the `pages.dev` origin because it isn't an authorized domain, just drop that one and keep the `c-direct.ca` entries. The sync will then only work on the live domain, which is fine — that's where pharmacists use it.

**9. Copy the Client ID.**
A dialog shows **Client ID** and **Client secret**. Copy the Client ID — it ends in `.apps.googleusercontent.com`.

**The client secret is not used in this flow. Don't send it to me and don't put it anywhere in the repo.** The Client ID is public by design (it ships in `supabase-config.js`, which is a publicly served file); the secret is not, and this browser flow has no use for it.

**10. Send me the Client ID.**
I paste it into `supabase-config.js` line 21, commit, and push. Cloudflare Pages redeploys on its own — about a minute.

**11. Test it end to end.**
Log in as a pharmacist → open the availability calendar. The pill should read **"Google Agenda : non connecté"** instead of "non configuré". Click the Google button:
- Consent screen appears (with the unverified warning — *Advanced* → *Go to C-Direct*)
- Grant access
- Pill turns to **"connecté"**, button label becomes **"Envoyer"**, and your C-Direct availabilities appear in Google Calendar

Two normal behaviours, not bugs: the token lasts about an hour, so **"session expirée" with a "Reconnecter" button is expected** after a while — there's no refresh token in this flow by design. And the page silently reconnects on later visits if you connected before.

**12. Publish the app.**
Google Auth Platform → **Audience** → **Publish app**. This moves it from *Testing* to *In production* so pharmacists outside the test-user list can connect. The unverified warning and the 100-user lifetime cap both still apply until step 13 completes.

**13. Submit for verification — start this at launch, not after.**
Google Auth Platform → **Verification center**. You'll need:
- **A justification for `calendar.events`** — why the app needs it and why a narrower scope won't do. Ours is genuinely easy: we write availability events into the pharmacist's own calendar, tagged `cdirect=dispo`, and we touch nothing else.
- **A demo video on YouTube, visibility Unlisted.** It has to show the whole path: a user starting the sign-in, seeing the consent screen, granting the scope, and the app then actually using it. Screen recording is fine.
- **Verified ownership of `c-direct.ca` in Google Search Console**, using an account that is Owner or Editor on this Cloud project — the same account from step 1. Google will not approve until site ownership is verified.
- A reachable privacy policy that says what you do with calendar data (step 5's link).

---

## Open decisions

1. 🧑 **Pricing** — leaning Option A ($195, five shifts then free); Option B ($199 hard cap) or another number still possible. Nothing is coded either way. Section 2 says the mechanics aren't a reason to avoid capping.
2. 🧑 **Interac-rail fee collection** — confirm how the $39 reaches C-Direct on that rail (section 2, "The Interac rail"). It decides how much of the cap work is actually needed.
3. 🧑 **Google Client ID** — steps 1–9 in section 4, then send me the ID (never the secret).

**Settled 2026-08-16:** share-link toggle goes in `parametres.html`; `disponibilites.html` stays untouched. Design A first (no rate shown to an unidentified visitor), design C later.

## Sources

- [Get started with the Google Auth Platform](https://support.google.com/cloud/answer/15544987?hl=en)
- [Manage App Audience](https://support.google.com/cloud/answer/15549945?hl=en)
- [Unverified apps](https://support.google.com/cloud/answer/7454865?hl=en)
- [Sensitive scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)
- [Configure the OAuth consent screen and choose scopes](https://developers.google.com/workspace/guides/configure-oauth-consent)
- Competitor pricing and claims: pasuneagence.com, reviewed 2026-08-16
