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

## 1. Pricing vs their Gold plan — 🧑 OPEN DECISION, no number picked

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

**Option A — $195, "five shifts a month, the rest are free."**
Clean sentence a pharmacist can repeat to another pharmacist without checking a table. The cap is a consequence of the rule rather than a number we invented. Undercuts them by $4.99/month.

**Option B — $199, "never more than $199 a month."**
Mirrors their price point exactly, which makes the comparison instant — but it also lands $0.99 under theirs, which reads as a deliberate needle rather than a fair price, and invites them to answer with $189. The sixth shift costs $4 and everything after is free, which is harder to explain than A.

### Before you lock either one

1. **Does the cap change the posted price?** Per the `c-direct-payments` architecture, the $39 isn't billed separately at month end — it's inside the all-in figure the pharmacy sees (`card_price = (locum_rate + cdirect_fee + 0.30) / (1 - 0.029)`, or `locum_rate + fee` on the Interac rail). So once a pharmacy crosses the cap, the price shown on the booking screen has to *drop* for the rest of the month. That's a real display and quoting change, not just a billing rule. Worth confirming against the payment architecture before committing.
2. **Per what, exactly?** Per pharmacy, per *calendar* month, presumably — but a pharmacy group with five branches will ask whether the cap is per branch or per group. Answer it before they ask.
3. **Free shifts aren't free to us.** Each one still runs the T-24h card authorization (that's $0 at Stripe unless captured) and still carries the chargeback and processing exposure we already absorb on Express accounts. Low, not zero.
4. **Their $449.99 job poster has no C-Direct equivalent.** Permanent-position postings are a separate product decision, not part of this cap.

**Status: open.** Nothing is coded, nothing is published, no number is committed. Tell me A, B, or a different figure.

---

## 2. Shareable read-only availability link — 🤖 not built, design agreed

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

### Hard constraint on where this lives

Per your rule of **2026-08-06**, `disponibilites.html` is off-limits — the pharmacist's Google-synced calendar is not to be touched without your explicit go-ahead. So:

- The share page is a **new file** (e.g. `dispo-partage.html`). It reads availability; it never becomes part of the calendar page.
- The share **toggle** has to live somewhere the locum can reach, and the obvious home is the calendar page. That means an edit to `disponibilites.html`. I will show you the exact before/after lines and wait for your approval before touching it — or we put the toggle in `parametres.html` instead and leave the calendar entirely alone. **Your call.**

---

## 3. Google Calendar sync — 🧑 one value away from working

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

## Open decisions, all yours

1. 🧑 **Pricing** — Option A ($195, five shifts then free), Option B ($199 hard cap), or another number. Nothing is coded either way.
2. 🧑 **Share-link toggle placement** — accept an approved edit to `disponibilites.html`, or keep the calendar untouched and put the toggle in `parametres.html`.
3. 🧑 **Google Client ID** — steps 1–9 above, then send me the ID (never the secret).

## Sources

- [Get started with the Google Auth Platform](https://support.google.com/cloud/answer/15544987?hl=en)
- [Manage App Audience](https://support.google.com/cloud/answer/15549945?hl=en)
- [Unverified apps](https://support.google.com/cloud/answer/7454865?hl=en)
- [Sensitive scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)
- [Configure the OAuth consent screen and choose scopes](https://developers.google.com/workspace/guides/configure-oauth-consent)
- Competitor pricing and claims: pasuneagence.com, reviewed 2026-08-16
