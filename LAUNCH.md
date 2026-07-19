# C-Direct — LAUNCH checklist

**Purpose:** the point-of-no-return steps to take C-Direct from private dev to public launch.
Work top to bottom. Nothing here runs automatically — you execute each step yourself.
Phases 1–5 are built, deployed, and tested; Phase 6 (polish) is in progress.

---

## 0. Pre-flight (do these first, reversible)

- [ ] **Run any pending SQL.** Confirm `sql/13-distance-code-postal.sql` has been run in Supabase → SQL Editor (lights up distance math on the board/detail).
- [ ] **Purge test data.** Remove the Cowork test rows so real users start clean:
  - contracts CD-100012 (completed) and CD-100013 (annulé), their candidatures, and invoices #1/#2. See the purge script in §6.
- [ ] **Verify each dashboard loads clean** for a real pharmacien and a real pharmacie account (not just admin).

## 1. Data-layer re-verification (RLS is the security boundary)

Run in Supabase → SQL Editor and confirm each returns what's expected:

- [ ] **RLS enabled on every table:**
  ```sql
  select relname, relrowsecurity from pg_class
   where relnamespace = 'public'::regnamespace and relkind = 'r'
   order by relname;
  -- every app table must show relrowsecurity = true
  ```
- [ ] **Anonymous leakage check.** From a logged-out browser console (anon key), each of these must return 0 rows / an empty array:
  `profiles, contrats, candidatures, factures, regles_reseau, sms_log, sms_queue, disponibilites, favoris`.
- [ ] **Cross-tenant check.** As pharmacien A, `supabase.from('candidatures').select('*')` returns only A's rows; A cannot read another pharmacist's candidature or a pharmacy's draft profile.
- [ ] **Admin gate.** `est_admin()` is security-definer and reads `profiles.role='admin'` — never a client-supplied value.
- [ ] **Tarif floor.** As a pharmacie, creating a contract below `regles_reseau.tarif_horaire_minimum` is rejected by the DB trigger (not just the UI).

## 2. Accounts & security

- [ ] **Admin 2FA.** Enable two-factor auth on the admin account(s) — both the Supabase dashboard login and the app admin account's email/Google.
- [ ] **Rotate the Twilio Auth Token** (it may have been briefly exposed during setup) and confirm the Worker still sends after rotation (`wrangler secret put TWILIO_AUTH_TOKEN`).
- [ ] **Confirm no service_role key** is in the repo, client code, or any committed file — it belongs only in Worker secrets.
- [ ] **Password reset / email.** Supabase built-in email is rate-limited; wire a custom SMTP (Resend) before scaling so reset/confirmation mails don't throttle.
- [ ] **Auth redirect allowlist.** In Supabase → Authentication → URL Configuration, whitelist `https://c-direct.ca/**` and `https://projet-1-1yi.pages.dev/**`.

## 3. Backups & resilience

- [ ] **Supabase backups enabled** (Project → Database → Backups) — confirm daily backups are on and note the retention window; consider Point-in-Time Recovery if on a paid tier.
- [ ] **Twilio balance alert.** Set a low-balance notification and auto-recharge (or a calendar reminder) so broadcasts never fail silently on an empty balance.
- [ ] **pg_cron health.** `select jobname, schedule, active from cron.job;` — confirm `factures-en-retard` (and any others) are active.
- [ ] **Worker health.** `POST /test` with the webhook secret returns 200 and a test SMS arrives.

## 4. Domain, SSL & delivery

- [ ] **Custom domain SSL.** `https://c-direct.ca` serves with a valid certificate; `www` and apex both resolve; the `/c/CD-XXXXXX` rewrite works on the live domain.
- [ ] **Twilio inbound (optional).** If you want in-app opt-out sync, configure the number's inbound webhook → Worker `/twilio-inbound` (the emergency-address form blocked this earlier; carrier STOP/ARRET works regardless).
- [ ] **SEO/social.** Titles, meta descriptions, and OpenGraph cards render correctly when a contract link is shared.

## 5. Remove the dev wall (the actual launch step)

- [ ] **Delete the Cloudflare Access application** that currently gates `c-direct.ca`.
  Cloudflare → Zero Trust → Access → Applications → remove the C-Direct app.
  *This is the single switch that makes the site public — do it last, after everything above is green.*
- [ ] Immediately re-confirm: an incognito visitor reaches the public pages but is still bounced from `/admin`, `/contrats`, dashboards, etc. by the app's own auth + RLS.

## 6. Test-user / test-data purge script

Run in Supabase → SQL Editor **before** launch to clear Cowork's test artifacts. Review the ref list first.

```sql
-- Delete Cowork test contracts + everything that cascades (candidatures, factures).
-- Adjust the reference list to whatever test rows exist at launch time.
with cibles as (
  select id from public.contrats
   where numero_reference in ('CD-100012','CD-100013')
      or notes ilike 'TEST-COWORK%'
)
delete from public.factures f
 using public.candidatures c
 where f.candidature_id = c.id
   and c.contrat_id in (select id from cibles);

delete from public.candidatures
 where contrat_id in (select id from cibles);

delete from public.contrats
 where id in (select id from cibles);

-- Optional: reset the CD reference sequence if you want real contracts to start clean
-- select setval('public.contrats_ref_seq', 100000, true);  -- next will be CD-100001

-- Verify nothing test-y remains:
select numero_reference, statut, notes from public.contrats order by created_at;
```

To remove a whole **test user account** (cascades their profile + data):
```sql
-- Supabase → Authentication → Users → delete the user (cascades via profiles FK),
-- or the app's own "Supprimer mon compte" (supprimer_mon_compte RPC).
```

---

## Sign-off

- [ ] A skeptical read of every public page on a phone (Règles du réseau, privacy/Loi 25, conditions).
- [ ] Loi 25 / CASL review signed off (Martin).
- [ ] Pick the launch day, delete the Access wall (§5), send the first onboarding invitations.

*Generated for C-Direct. Restore points tagged per phase (`restore-phase-1` … `restore-phase-5`); nothing here is irreversible except §5 and §6 — do those last, with backups confirmed.*
