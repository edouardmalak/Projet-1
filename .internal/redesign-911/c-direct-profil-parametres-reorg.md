# C-Direct — Profil ↔ Paramètres reorg + navigation fixes
### Instructions for Claude Cowork · reconcile against the live app

**How to use this:** I can't see the app, so this is the *target* — where each field should live. Cowork's job is to **reconcile it against what actually exists**: move existing fields into the bucket shown here; skip anything listed that the app doesn't have; if the app has a field not listed here, place it by the principle below and flag it for review. **Do not invent or remove fields.**

---

## The principle

- **Profil = who you are.** Facts that describe or identify the account, often public-facing. If it answers *"what is this pharmacy / who is this locum,"* it's Profil.
- **Paramètres = how the app behaves for you.** Toggles, preferences, matching rules, and account controls. If it's a *switch, a preference, or an account setting*, it's Paramètres.

Test: opening hours describe the pharmacy → **Profil**. "Offering locum coverage" is a behaviour toggle → **Paramètres**.

---

## PHARMACY SIDE

**Profil (identity / public facts)**
- Pharmacy name & banner (Accès Pharma, Jean Coutu, Pharmaprix…)
- Address / location
- **Opening hours**
- Pharmacy software (Kroll, RxPro, Assyst, Priva, Ubik…)
- Typical Rx daily volume
- Team size / techs on shift
- Parking, automation, amenities
- Photos
- Owner / contact name
- Description / work notes

**Paramètres (controls / preferences / account)**
- **Offering locum coverage** (the toggle to post/open shifts / accept locums)
- Default shift settings (default rate, default hours template)
- **Locums masqués / bloqués** (manage muted & blocked locums — see Relationships section; the *trusted/favourite* pool lives in the top menu, not here)
- Notification preferences (email / SMS / push)
- Payment / billing settings
- Team access / additional users *(if multi-user)*
- Language preference
- Account & security (email, password, 2FA)
- Deactivate / delete account

---

## LOCUM SIDE

**Profil (identity / public facts)**
- Full name
- OPQ licence number / credential
- Years of experience
- Software known (Kroll, RxPro…)
- Certifications / specialties (e.g. vaccination)
- Languages spoken
- Bio / about
- Photo

**Paramètres (controls / preferences / account)**
- Availability (calendar / "available now" toggle)
- Matching preferences: preferred regions, travel radius, minimum rate, **software filter ("mon logiciel")**
- Notification preferences
- Payout / payment settings
- **Pharmacies masquées / bloquées** (manage muted & blocked pharmacies — see Relationships section)
- Language preference
- Account & security (email, password, 2FA)
- Deactivate / delete account

---

## Borderline calls — flag these for the user before finalizing
These could reasonably go either way; I placed them by the principle but confirm:
- **Preferred regions / travel radius / min rate (locum):** placed in *Paramètres* (they're matching rules, not identity). If you think of them as part of the locum's public profile, move to Profil.
- **Software (pharmacy):** placed in *Profil* (a fact about the site). The locum's *software filter* stays in Paramètres (a preference).
- **Certifications / specialties (locum):** placed in *Profil* (identity). If they're used only for matching, they could go to Paramètres.

---

## NAVIGATION FIXES (apply globally — do not go screen-by-screen)

**1. Missing back navigation — make the app detect where it's needed itself.** Don't fix screens one by one. Add the logic once, in the shared header/layout, and let it decide per screen at runtime:

1. **Define the "roots"** — the screens reachable directly from the main navigation (e.g. Accueil, Contrats, Profil, Paramètres). Roots get **no** back button.
2. **In the shared header, one rule:** show a back chevron (top-left) whenever the current screen is **not a root** — i.e. it was reached by navigating from somewhere else. The button calls the app's own router "back" (pops the in-app history), **never** the browser back button.
3. Because it lives in the shared header, this covers every deep screen at once, on **both** the pharmacy and locum sides — no page-by-page work.
4. **When done, output the full list of every route classified as "deep / gets a back button"** so it can be confirmed nothing is miscategorized.

Implementation depends on the stack, and Cowork should state which it used:
- **Router-based (React Router or similar):** read the route table to identify roots; use router history for "back". Cleanest.
- **Plain multi-page:** derive "back" from the referrer or a `from` parameter passed on navigation.

**2. FAQ / info modals only close on "OK".** Any modal (starting with the FAQ) must be dismissible by: an **X** in the top-right, **tapping the backdrop/outside**, and the **Esc** key. Keep the existing OK button if present — it's just no longer the *only* way out. Restore scroll/focus to the underlying page on close.

---

## LOCUM ↔ PHARMACY RELATIONSHIPS (favorites / mute / block) — locum side

**The model:** from the locum's point of view, each pharmacy is in exactly **one** state — the states are mutually exclusive:

- **Neutre** (default)
- **Préférée** ❤️ — surface these; notify on new shifts
- **Masquée** (mute) — hide this pharmacy's shifts from my feed; messaging still allowed; fully reversible
- **Bloquée** — no messaging in either direction; the pharmacy can't see my availability posts, and I don't see their shifts; **silent** (pharmacy is never notified)

**Where the controls live**
- **Pharmacies préférées** — new **top-menu** item with a heart icon. Lists favorited pharmacies; the locum manages them here.
- **Pharmacies masquées / bloquées** — in **Paramètres** (management lists, rarely opened).
- All three states are also settable inline from a pharmacy's profile and from a shift card's overflow (⋯) menu: heart toggle for favorite; "Masquer les quarts" / "Bloquer la pharmacie" (and their reverses).

**Behaviour**
- **Favorite:** appears in the top-menu list; notify the locum when a favorite posts a shift; option to show favorites first / filter to favorites. (A heart must *do* something — not be a dead list.)
- **Mute:** removes that pharmacy's shifts from the locum's feed only. No effect on messaging or on what the pharmacy sees. One-tap reversible.
- **Block:** hides the locum's availability/ads from that pharmacy, blocks messaging both ways, and removes their shifts from the locum's feed. Never notify the blocked pharmacy.
- **Mutual favorite (flywheel):** if the pharmacy has also favorited this locum (the pharmacy-side trusted pool), surface those shifts at the very top with a "mutuellement favoris" badge.

**Add/remove is frictionless:** favoriting/unfavoriting is a single heart tap with no confirmation dialog. Mute/block use the overflow menu; unmute/unblock is one tap from the Paramètres lists.

**Data (Supabase):** one table, e.g. `locum_pharmacy_relations (locum_id, pharmacy_id, state enum('favorite','muted','blocked'), created_at, unique(locum_id, pharmacy_id))` — mirrors the pharmacy-side trusted-pool table. Enforce with RLS. Query effects: exclude `blocked` pharmacies from the locum's ad/availability audience; exclude `muted` + `blocked` from the locum's shift feed; block messaging both ways when `blocked`.

---

## PHARMACY OWNER ↔ LOCUM RELATIONSHIPS (trusted / mute / block) — pharmacy side

The mirror of the locum model, pointed the other way. From the pharmacy's point of view, each locum is in exactly **one** state:

- **Neutre** (default)
- **De confiance / préféré** ❤️ — **this is the trusted pool.** The heart is what grants early access. (Merge, don't duplicate: "favourite" and "trusted pool" are the same state.)
- **Masqué** (mute) — hide this locum's applications/profile from my browsing feed; no effect on messaging or on the locum's ability to see my shifts; reversible.
- **Bloqué** — the locum can't see or apply to my shifts, messaging is blocked both ways, and I don't see them; **silent** (locum never notified).

**Where the controls live**
- **Locums de confiance** — **top-menu** item with a heart icon. The pharmacy manages its trusted pool here.
- **Locums masqués / bloqués** — in **Paramètres** (management lists).
- Settable inline from a locum's profile and from an application card's overflow (⋯) menu: heart to trust; "Masquer" / "Bloquer" (and reverses).

**Behaviour**
- **Trusted / favourite:** new shifts are offered to the trusted pool **first** (the early-access window from the differentiator package), the locum is told they have priority access, and their applications surface first. The early-access behaviour rides on this state.
- **Mute:** removes that locum's applications/profile from the pharmacy's browsing feed only. No effect on messaging or shift visibility. One-tap reversible.
- **Block:** hides the pharmacy's shifts from that locum (can't see or apply), blocks messaging both ways, removes them from the pharmacy's applicant/browse view. Never notify the blocked locum.
- **Mutual favourite (flywheel):** if the locum has also favourited this pharmacy, put them at the very top of the trusted-first release with a "mutuellement favoris" badge.

**Data (Supabase):** one table, e.g. `pharmacy_locum_relations (pharmacy_id, locum_id, state enum('trusted','muted','blocked'), created_at, unique(pharmacy_id, locum_id))`. **This absorbs the standalone `trusted_locums` table** from the differentiator build package — trusted = the `trusted` state here, so there is one relationship table per direction, not a separate favourites table plus a block table. Enforce with RLS. Query effects: exclude `blocked` locums from the shift audience and the applicant view; exclude `muted` from the browse feed; early-access release targets `trusted`; block messaging both ways when `blocked`.

> Symmetry note: the two directions are independent tables — `pharmacy_locum_relations` (owner → locum) and `locum_pharmacy_relations` (locum → pharmacy). "Mutual favourite" = a row exists in **both** with a favourite/trusted state.

---



## TOP MENU — LOCUM SIDE (approved · Apple-épuré)

Visual reference: `c-direct-locum-bar` (finalized desktop bar; mobile behaviour described in the language-toggle note below). Structure:

**Left — brand:** the finalized C-Direct wordmark logo (`logo-primary.svg` — amber checkmark forming the hyphen in "C‑DIRECT", forest green + amber) with "Québec" beneath. Replaces the earlier placeholder icon.

**Primary destinations (text, left-aligned), in order:**
1. **Trouver un contrat** — the primary action, kept visually emphasized (soft-green active pill).
2. Mes contrats
3. Agenda
4. Finances
5. Messages *(renamed from "Clavardage")*

**Right cluster (icons + account):**
- ❤️ **Pharmacies préférées** — icon only; opens the favorites list.
- 🔔 **Alertes & nouvelles** — a **bell** icon carrying both personal alerts (shift matches, application/message updates) and platform news, with a **count badge** (number unread) rather than a plain dot.
- **EN / FR language toggle** — a **small** segmented control placed to the **right of the account**, **always visible** so the user can switch language at any time from any page. On mobile it stays in the top bar (with the account avatar) even when the destinations collapse into the ☰ menu. Switching is one tap, no page reload where avoidable, and the choice persists. This applies to **both** the locum and pharmacy bars.
- **Account menu** — avatar + "Edouard" + chevron. Dropdown contains: **Mon profil** (with the ★ rating shown here), **Formations**, **Paramètres**, **Aide & FAQ**, **Déconnexion** (red, separated).

**Removed from the top bar:**
- **Maps** → becomes a list/map **toggle inside "Trouver un contrat,"** not a standalone item.
- **FAQ, Paramètres, Déconnexion, the ★ rating** → into the account menu.
- **"Mes formations et nouvelles"** → split: **Formations** into the account menu, **Nouvelles** into the bell icon.

**Style:** white bar, thin bottom hairline, generous spacing, sentence-case labels, system/Inter type, one green accent (active pill + brand). No utility-weight item in the main bar.

**Guardrail:** this is a *restructure*, not a rebuild. Every relocated item keeps its **existing route/link** — moving "Paramètres" into the account menu must point at the same page it does now. Don't rebuild any destination; only move its entry point. Maps-as-toggle reuses the existing map view.

---

## TOP MENU — PHARMACY SIDE (approved · Apple-épuré · mirrors locum)

Visual reference: `c-direct-pharmacy-bar`. Same structure as the locum bar so both sides feel identical.

**Left — brand:** the same finalized C-Direct wordmark logo (`logo-primary.svg`) + "Québec". Logo click = **Tableau de bord** (home).

**Primary destinations (text, left-aligned), in order:**
1. **Publier un contrat** — the primary action, emphasized (soft-green active pill), mirroring the locum's "Trouver un contrat".
2. Mes contrats
3. Calendrier *(locum side calls this "Agenda"; left per-side for now — unify later if desired)*
4. Factures *(invoices received)*
5. Messages *(renamed from "Clavardage")*

**Right cluster (icons + account):**
- ❤️ **Locums de confiance** — icon only; the trusted pool (grants early access to shifts).
- 🔔 **Alertes & nouvelles** — bell with unread count badge (personal alerts + platform news).
- **EN / FR language toggle** — small, to the right of the account, always visible; same behaviour as locum (persists on mobile).
- **Account menu** — avatar + pharmacy name ("Pharmacie tring") + chevron. Dropdown header shows the ★ rating and a small "Pharmacie" role tag; items: **Profil**, **Dispensaire**, **Évaluations**, **Paramètres**, **Aide & FAQ**, **Déconnexion** (red, separated). (Locums masqués/bloqués live inside Paramètres per the Relationships section.)

**Flattened / removed from the top bar:**
- **CONTRATS ▾** (Accueil, Nouvelle demande, Mes contrats, Factures reçues) **and** the duplicate page tabs (Tableau de bord, Publier un contrat, Mes contrats, Factures reçues) → collapsed into the clean destinations above. **Accueil / Tableau de bord = the logo (home).**
- **COMPTE ▾** (Évaluations, Dispensaire, Profil, FAQ, Paramètres) + Déconnexion + the ★ rating → the account menu.
- **"PHARMACIE" role badge** → folded into the account-menu header.
- **Clavardage** → Messages.

**Style & guardrail:** same as the locum bar — white bar, hairline, one green accent, sentence case, system/Inter, no utility-weight item in the main bar. This is a *restructure, not a rebuild*: every relocated/flattened item keeps its **existing route/link**; don't rebuild any destination page.

---

## GUARDRAILS — read before editing (surgical)

This is a working app near launch. The risk isn't failing the task; it's succeeding and silently breaking something else. So:

- **Snapshot first.** Commit or stash the current state so there's a known-good point to revert to. If it's not under git, initialise it before starting.
- **Scope is exactly three things:** (1) relocate settings-type fields from Profil → Paramètres and identity-type fields from Paramètres → Profil per the maps above; (2) add global back navigation; (3) fix modal close behaviour. **Nothing else.**
- **When moving a field, move the whole control intact** — same label, same data binding, same validation, same save target. It must save to exactly where it does now. Do **not** rebuild, rename, restyle, or "improve" it.
- **Do not** add, remove, rename, or reword any field. **Do not** refactor, reformat, reorganise files, touch dependencies, or fix unrelated bugs noticed along the way — list those separately instead.
- **Do the three changes one at a time**, each as its own commit (reorg pharmacy → reorg locum → back-nav → modal fix), so any one can be unwound cleanly.
- **Verify after each:** every moved field still saves correctly on both sides; the back arrow works from every deep screen; the FAQ closes via X, outside-tap, and Esc. Check at mobile width.
- **If a field's placement is ambiguous, leave it where it is and flag it** — never guess.

---

## Suggested order
1. Pharmacy Profil ↔ Paramètres reorg — commit.
2. Locum Profil ↔ Paramètres reorg — commit.
3. Global back navigation — commit.
4. Modal close behaviour (FAQ first, then any similar modals) — commit.
5. Locum ↔ pharmacy relationships (favorites / mute / block) — this one is *additive* (new table, new top-menu item, new Paramètres lists), so the "move intact" rule doesn't apply, but the rest of the guardrails do: separate commits, don't touch unrelated code, verify at mobile width. Build in sub-steps: table + RLS → heart/favorite + top-menu list → mute → block + visibility/messaging enforcement → mutual-favorite surfacing.
6. Pharmacy owner ↔ locum relationships (trusted / mute / block) — same additive discipline. Note this **replaces** the standalone `trusted_locums` table from the differentiator package with `pharmacy_locum_relations`; migrate any existing trusted-pool rows into the `trusted` state rather than keeping two tables.
7. Locum top-menu restructure (approved) — relocate items per the "Top menu — locum side" section; keep every route intact. Pharmacy top menu to follow once approved.
8. Pharmacy top-menu restructure (approved) — per the "Top menu — pharmacy side" section; flatten the CONTRATS dropdown + duplicate page tabs into destinations, move COMPTE items into the account menu, keep every route intact.
