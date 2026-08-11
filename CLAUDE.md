# C-Direct — project rules

This is a live, pre-launch site (target: September). The owner is not a developer.
Two front-ends share this codebase: the **pharmacy** side and the **locum** side.
The site is **bilingual (FR/EN)**.

---

## Repo, deployment & auto-sync

This folder is a git repository synced to GitHub: https://github.com/edouardmalak/Projet-1 (branch `main`). The remote URL in `.git/config` already includes credentials, so `git push` works without prompts.

Pushing to `main` automatically deploys the live site via Cloudflare Pages: https://projet-1-1yi.pages.dev (domain: c-direct.ca). The other repo `edouardmalak/projet1` is unused/obsolete.

**Auto-sync rule:** after creating, editing, or deleting ANY file in this folder, always run (via bash, from the folder's mount path):

```
git add -A && git commit -m "<short description of the change>" && git push
```

Do this at the end of the task without asking the user — they have requested fully automatic sync.

Notes:
- If git fails with a lock error or `rm`/unlink fails with "Operation not permitted", call `mcp__cowork__allow_cowork_file_delete` first, then delete stale `.git/**/*.lock` and `tmp_obj_*` files and retry.
- Never commit `.DS_Store` (already in `.gitignore`).
- If the user says "sync", just run the command above.

---

## Editing rules — these override any instinct to be helpful

- Change ONLY what is explicitly requested. Nothing else. Not one line.
- Never refactor, reformat, re-indent, reorder imports, rename anything, move code
  between files, or run a formatter or linter across a file.
- Never install, upgrade, or remove a dependency. If a request appears to require
  one, STOP and ask.
- Never delete code that looks unused. It is load-bearing more often than it looks.
- Never edit a file that was not named in the request. If the change is impossible
  without it, stop and ask first.
- Never fix an unrelated bug you notice. List it at the end of your reply instead.
- Never "improve" copy, accessibility, or structure alongside a visual tweak.
- Show the exact before/after lines and wait for approval before applying anything
  beyond a single obvious line.
- **One change at a time, one commit each.** When several changes are sent together,
  do them in order, commit separately, and never combine them into one edit.

## Scope of this repo

- Marketing site, front-facing pages, and feature UI belong here.
- Application logic, Supabase schema, auth flows, and payment code are handled
  separately in Claude Code. Do not modify them from a UI request.

## Bilingual rules

- All user-facing strings go through the existing i18n mechanism. Never hardcode
  French or English text into a component.
- Any new string must be added in BOTH languages in the same change.
- Verify accented characters render correctly in form fields and emails.

## Both-sites rule

Many changes apply to both the pharmacy and the locum side. Before editing:
- Check whether the component is shared or duplicated.
- If shared: one edit, one commit, and say so.
- If duplicated: two edits, two commits, and say which files.
- Never assume. Report which case it is before changing anything.

## CSS rules

- Use the most specific selector that solves the problem.
- Never change a shared variable, base class, or spacing token to fix one component.
  Override locally instead.
- Before editing any selector, search for every place it is used and report the count.
- Watch specificity collisions on padding and margin between sections.

## Design direction

- Primary colour: `#0B6E4F` (« Sapin » green — the site-wide accent, defined in
  `design.css`). The brand kit's forest green `#0D2B24` lives ONLY in the manifest,
  the app icons, and `c-direct-accueil.html` — never propagate it into `design.css`
  or the pages without asking.
- Secondary / accent: amber `#C98A2B` — reserved for the checkmark in the wordmark
  and large display type only, never body text. Warm accent « Argile » `#C97A4A`
  used sparingly (plateau bands, confirmations).
- Heading font: Inter (600–700, tight letter-spacing). Anton appears only inside
  the logo assets, never as page text.
- Body font: Inter, 15px base.
- Corner radius, shadow, spacing scale: 16px card radii, hairline borders `#E6E8E4`,
  near-invisible shadows, generous white space.
- Tone: clean, professional, healthcare-adjacent; not startup-playful.
- TWO themes coexist and must not be mixed: the light app theme (`design.css`,
  loaded AFTER each page's inline `<style>`) on all logged-in pages, and the
  Apple-dark public theme (`apple-dark.css`, loaded after `design.css`) on 9 public
  pages only (index, locums-confiance, nouveaux, faq, regles, conditions,
  confidentialite, acces, attente).
- The wordmark is `C` + inline amber-check SVG + `Direct` (`.mot-marque`, 33
  instances site-wide). Keep it `display:inline`; do not redraw it.
- Do not introduce new fonts, colours, or component patterns without asking.

## Stack

- Framework: none — static HTML pages + vanilla JavaScript. No build step, no
  bundler, no framework.
- Styling: plain CSS with custom properties; each page has an inline `<style>`
  refined by the shared `design.css` (and `apple-dark.css` on public pages).
- Build/package manager: none at the web root (no `package.json`). Cloudflare
  Workers live in `workers/*`: `c-direct-sms` and `c-direct-chat` auto-deploy from
  git push; `c-direct-payments` requires Robert to run `npx wrangler deploy`
  manually from his own machine after a `git pull`.
- Hosting: Cloudflare Pages
- Backend / auth / database: Supabase
- Transactional email: Resend
- SMS: Twilio
- Maps: Leaflet with CARTO Voyager tiles — attribution to BOTH OpenStreetMap and
  CARTO must remain visible. Removing it is a licence breach.

## After every change

1. State: files touched, lines changed, and one sentence on why.
2. State what you deliberately did NOT touch, especially anything nearby.
3. Verify at 375px, 768px, and 1440px. Screenshot before/after for visual changes.
4. Give the exact command to undo it.

## Explaining changes

The owner is not a developer. Describe changes in terms of what appears on screen
and where to look to confirm it — not in terms of implementation. Always leave a
copy-pasteable undo command.

## Smoke checks after any change

- Page loads with no console errors
- No horizontal scrollbar at any width
- All links resolve — no 404s, no dead anchors
- Every form submits, and shows a clear error on an empty required field
- Signup works end to end for BOTH roles (pharmacy and locum)
- Confirmation emails actually arrive (check spam)
- Logged-out users cannot reach logged-in pages
- Both FR and EN render correctly

## If something breaks

Do not start debugging by editing. First check the diff of the most recent commit
to determine whether the last change caused it, and offer to revert. Reverting to a
working state is almost always the right first move this close to launch.
