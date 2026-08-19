# C-Direct — Build Package for Claude Cowork
### Three differentiator features: Work-Conditions Transparency · Trusted-Pool Rebooking · Listing-Accuracy Score

**Stack assumptions:** Supabase (Postgres + Auth + RLS), Cloudflare Pages frontend.

**Before you run anything — read this:**
- The SQL below assumes existing tables named `pharmacies`, `shifts`, and `profiles` (locum/pharmacy users). **Confirm the real table and column names in Supabase first** and adjust the `references` targets. Do not create duplicate tables.
- Apply these as a **new migration**. Do not alter or drop existing columns.
- Build only the three features below. **Do not redesign existing pages, cards, or components.** Add to them.
- All new tables need **Row Level Security** enabled. Example policies are included but must be adapted to the real auth model before going live.

---

## FEATURE 1 — Work-Conditions Transparency

**Goal:** Show the locum what the day actually looks like *before they apply*. This is the #1 differentiator — it kills "unpredictable work conditions."

### Schema

```sql
-- Software the pharmacy runs (locums filter and match on this)
create type pharmacy_software as enum (
  'kroll', 'rxpro', 'assyst_rx', 'priva', 'ubik', 'logipharm', 'reflexrx', 'other'
);

create type parking_type as enum ('free_onsite', 'paid_onsite', 'street', 'none');

-- Stable, pharmacy-level work profile (defaults)
alter table pharmacies
  add column if not exists software            pharmacy_software,
  add column if not exists rx_volume_daily      integer,        -- typical Rx/day
  add column if not exists tech_count_typical   integer,        -- techs on a normal shift
  add column if not exists has_automation       boolean default false,  -- robot / auto-dispense
  add column if not exists parking              parking_type,
  add column if not exists work_notes           text;           -- free text, e.g. "busy 4-6pm"

-- Per-shift overrides (a given shift may differ from the pharmacy norm)
alter table shifts
  add column if not exists rx_volume_expected   integer,        -- overrides pharmacy default if set
  add column if not exists tech_count_shift      integer,
  add column if not exists lunch_coverage        boolean,        -- is the locum relieved for lunch?
  add column if not exists conditions_note       text;           -- shift-specific note
```

**Display resolution rule (frontend/logic):** for each field, show the shift-level value if present, otherwise fall back to the pharmacy-level default. Label clearly which is which is not necessary — just show the resolved value.

### UI spec
On the contract/shift card and the shift detail view, add a **"Conditions de travail"** block showing, as labeled chips or a small grid:
- **Logiciel:** Kroll / RxPro / etc.
- **Volume:** ~250 Rx/jour
- **Équipe:** 2 ATP en poste
- **Dîner couvert:** Oui / Non
- **Automatisation:** Robot ✓ (only show if true)
- **Stationnement:** Gratuit sur place
- Free-text note underneath if present.

Keep it compact on the card (software + volume + techs), full grid on the detail page. French labels, sentence case.

### Bonus — software-match filter (cheap, high value)
Add a filter on the shift-listing page: **"Mon logiciel"** — a multi-select of `pharmacy_software` values. When set, filter shifts to matching software (or sort matches to the top rather than hiding non-matches — your call; sorting is friendlier). Store the locum's known-software list on their profile:

```sql
alter table profiles
  add column if not exists known_software pharmacy_software[];
```

---

## FEATURE 3 — Trusted-Pool Rebooking (favorites + early access)

**Goal:** A pharmacy marks locums it trusts; new shifts are offered to that pool *first* before hitting the open marketplace. Solves "unfamiliar locum" fear and builds a repeat-work flywheel competitors can't copy once pools exist.

### Schema

```sql
-- A pharmacy's trusted locums
create table if not exists trusted_locums (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null references pharmacies(id) on delete cascade,
  locum_id     uuid not null references profiles(id)  on delete cascade,
  created_at   timestamptz not null default now(),
  unique (pharmacy_id, locum_id)
);

create index if not exists idx_trusted_locums_locum on trusted_locums(locum_id);

-- Early-access window on shifts: trusted pool sees it before the public
create type shift_visibility as enum ('trusted_first', 'public');

alter table shifts
  add column if not exists visibility        shift_visibility not null default 'public',
  add column if not exists public_release_at timestamptz;   -- when a 'trusted_first' shift opens to everyone
```

### Logic
When a shift is `trusted_first`:
- Only locums in that pharmacy's `trusted_locums` can see/apply **until `public_release_at`**.
- At `public_release_at` (or immediately if null), it becomes visible to all.
- A simple query for "shifts this locum can see":

```sql
-- shifts visible to a given locum (:locum_id) right now
select s.*
from shifts s
where s.status = 'open'
  and (
    s.visibility = 'public'
    or s.public_release_at <= now()
    or exists (
      select 1 from trusted_locums t
      where t.pharmacy_id = s.pharmacy_id
        and t.locum_id = :locum_id
    )
  );
```

### UI spec
- **Pharmacy side:** on a completed shift or a locum's profile, a **"Ajouter à mes pharmaciens de confiance"** button (star/heart). A "Mes pharmaciens de confiance" list in the pharmacy dashboard.
- When posting a shift: a toggle **"Offrir d'abord à mes pharmaciens de confiance"** with a duration ("pendant 24 h" → sets `public_release_at = now() + interval '24 hours'`).
- **Locum side:** a badge on shifts they get early access to — **"Accès prioritaire · pharmacie de confiance"** — so they feel the relationship value.

---

## FEATURE 4 — Listing-Accuracy Score

**Goal:** After a shift, the locum rates whether reality matched the listing. Feeds a public **accuracy score** per pharmacy. This is what makes Feature 1 *trustworthy* instead of just marketing — pharmacies can't overstate conditions without it showing.

### Schema

```sql
create table if not exists shift_feedback (
  id                uuid primary key default gen_random_uuid(),
  shift_id          uuid not null references shifts(id)    on delete cascade,
  locum_id          uuid not null references profiles(id)  on delete cascade,
  accuracy_rating   smallint not null check (accuracy_rating between 1 and 5),
  volume_matched    boolean,   -- was the Rx volume as advertised?
  staffing_matched  boolean,   -- was the team/tech count as advertised?
  comment           text,
  created_at        timestamptz not null default now(),
  unique (shift_id, locum_id)   -- one feedback per locum per shift
);

create index if not exists idx_shift_feedback_shift on shift_feedback(shift_id);

-- Rolling accuracy score per pharmacy (recompute-friendly view)
create or replace view pharmacy_accuracy as
select
  s.pharmacy_id,
  count(f.id)                                   as ratings_count,
  round(avg(f.accuracy_rating)::numeric, 2)     as accuracy_avg,
  round(avg((f.volume_matched)::int)::numeric,   2) as volume_match_rate,
  round(avg((f.staffing_matched)::int)::numeric, 2) as staffing_match_rate
from shift_feedback f
join shifts s on s.id = f.shift_id
group by s.pharmacy_id;
```

### Logic
- Prompt the locum for feedback **only after a shift is marked completed** (tie into your existing completion/confirmation step).
- Show the pharmacy's `accuracy_avg` on its listings once it has a minimum sample (e.g. hide until `ratings_count >= 3` to avoid a single rating defining a pharmacy).

### UI spec
- **Post-shift prompt (locum):** three quick inputs — accuracy 1–5 stars, "Volume conforme à l'annonce? Oui/Non", "Équipe conforme? Oui/Non", optional comment.
- **On listings:** a small badge near the pharmacy name — **"Fiabilité de l'annonce · 4,6/5"** — shown only past the minimum sample threshold.
- Keep it separate visually from any general star rating so "did it match the listing" reads as its own trust signal.

---

## Row Level Security (adapt before launch)

Enable RLS on the new tables and add policies. Example shapes — **adjust to your actual auth/claims model**:

```sql
alter table trusted_locums enable row level security;
alter table shift_feedback  enable row level security;

-- Trusted list: a pharmacy manages its own; a locum can see rows where they're trusted
create policy "pharmacy manages own trusted list"
  on trusted_locums for all
  using  (pharmacy_id = auth.uid())    -- replace with your pharmacy->user mapping
  with check (pharmacy_id = auth.uid());

create policy "locum sees own trusted status"
  on trusted_locums for select
  using (locum_id = auth.uid());

-- Feedback: a locum writes their own; pharmacies read feedback about them
create policy "locum writes own feedback"
  on shift_feedback for insert
  with check (locum_id = auth.uid());
```

> Note: `auth.uid()` returns the auth user id. If `pharmacies`/`profiles` use a separate id, map through the correct join or a security-definer function. Confirm this before shipping — getting RLS wrong here leaks the trusted lists and feedback.

---

## Suggested build order
1. **Feature 1** first (schema + card block + software filter) — it's the visible differentiator and the other two build on the conditions data.
2. **Feature 4** next — it protects Feature 1's honesty.
3. **Feature 3** last — highest value long-term, but the trusted-pool flywheel only matters once there's traffic.

## Guardrails (repeat to Cowork)
- New migration only; no changes to existing columns or tables.
- Add to existing cards/pages; do not restyle or reorganize them.
- Enable RLS on every new table before it goes live.
- French UI copy, sentence case, consistent with the existing site.
