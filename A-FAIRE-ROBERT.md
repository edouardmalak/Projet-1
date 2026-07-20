# What you need to do — plain-language guide

Everything below is a manual step that I (Cowork) can't fully do on my own. I've marked each one:
- 🤖 = **I can do this for you** (just ask) — your Supabase dashboard is logged in, so I can run the database steps.
- 🧑 = **only you can do this** (it needs a password, an API key, or your phone).

The website already works and won't break if you do none of this. These steps just *switch on* the newest features and get you launch-ready.

---

## PART 1 — Run 3 database files (5 minutes) 🤖

These are small text files of database instructions. They turn on: real distance math, the "N pharmacists available" hint, and the language + confirmed-contract email.

**The easy way:** just tell me "run the SQL files" and I'll do all three through your browser.

**If you'd rather do it yourself:**
1. Go to **supabase.com** → open your **c-direct** project → click **SQL Editor** (left menu).
2. For each file below: open it from the `sql/` folder, copy everything, paste into a new query, click **Run**.
   - `sql/13-distance-code-postal.sql`
   - `sql/14-fsa-compatibles.sql`
   - `sql/15-langue-et-confirmation.sql`
3. Each should say "Success". That's it.

**What they do:** #13 shows real driving distances/allowances on contracts. #14 powers the "X pharmacists compatible on {date}" line when you post a contract. #15 adds the French/English language choice and prepares the confirmed-contract email.

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
