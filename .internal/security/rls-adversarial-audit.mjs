#!/usr/bin/env node
// =====================================================================
// C-Direct — Phase 1 adversarial RLS/RPC audit (BLOCKING)
// ---------------------------------------------------------------------
// WHAT THIS IS
//   An automated adversarial access test. It authenticates as REAL test
//   users and ATTEMPTS to read/write data that is not theirs. It does NOT
//   test "does the app work" — it tests "can a logged-in user reach what
//   isn't theirs." Every DENIED is a PASS; every row returned that should
//   not be reachable is a FAIL.
//
// WHY PLAIN fetch (no dependency)
//   The web root has no package.json and the standing rule forbids adding
//   dependencies. Node 18+ has global fetch, so this script uses the
//   Supabase REST (PostgREST) and Auth REST endpoints directly — nothing
//   to `npm install`.
//
// HOW THE TABLE LIST IS BUILT (from the LIVE schema, never from memory)
//   1. If SERVICE_ROLE_KEY is provided, it is used ONLY to enumerate the
//      authoritative table list from information_schema via the
//      `list_public_tables` helper (see companion SQL below). It is never
//      used to perform the adversarial reads themselves.
//   2. If no service_role key is given, the list falls back to the tables
//      PostgREST exposes in its OpenAPI spec at /rest/v1/.
//   Either way the list comes from the running database, so a newly added
//      table cannot be silently skipped.
//
// SECURITY NOTE ON PLACEMENT
//   Cloudflare Pages serves the whole repo. Before this file lands in the
//   repo, its directory MUST be added to the _middleware.js block list
//   (e.g. add '/security/' to PREFIXES_BLOQUES) OR excluded from build
//   output. Do not deploy an auth-carrying test script to a public path.
//   Credentials come from env vars / a local audit-config.json that is
//   gitignored — never hardcode them here.
//
// USAGE
//   1. Copy audit-config.example.json -> audit-config.json and fill in the
//      four test users (locumA, locumB, pharmacyP, pharmacyQ) with real
//      credentials created on the LIVE project, plus a known row id owned
//      by each so cross-user attempts have concrete targets.
//   2. export SUPABASE_URL=https://<ref>.supabase.co
//      export SUPABASE_ANON_KEY=sb_publishable_...
//      (optional) export SUPABASE_SERVICE_ROLE_KEY=...   # enumeration only
//   3. node rls-adversarial-audit.mjs
//   Output: console summary + rls-audit-results.json (every table, every
//   attempt, PASS/FAIL). Any FAIL exits non-zero (CI-friendly).
// =====================================================================

import fs from 'node:fs';

const CFG_PATH = process.env.AUDIT_CONFIG || './audit-config.json';
const URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY || null;

if (!URL || !ANON) {
  console.error('Missing SUPABASE_URL or SUPABASE_ANON_KEY env vars. See header.');
  process.exit(2);
}
if (!fs.existsSync(CFG_PATH)) {
  console.error(`Missing ${CFG_PATH}. Copy audit-config.example.json and fill it in.`);
  process.exit(2);
}
const cfg = JSON.parse(fs.readFileSync(CFG_PATH, 'utf8'));

const results = { generated_at: new Date().toISOString(), supabase_url: URL, attempts: [], summary: {} };
let fails = 0, passes = 0;

function record(actor, target, action, expected, observed, detail) {
  const pass = expected === observed;
  if (pass) passes++; else fails++;
  results.attempts.push({ actor, target, action, expected, observed, verdict: pass ? 'PASS' : 'FAIL', detail });
  const tag = pass ? 'PASS' : 'FAIL';
  console.log(`[${tag}] ${actor} -> ${action} ${target} | expected ${expected}, observed ${observed}${detail ? ' | ' + detail : ''}`);
}

// ---- auth: password grant, returns access_token -------------------------
async function signIn(email, password) {
  const r = await fetch(`${URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!r.ok) throw new Error(`sign-in failed for ${email}: ${r.status} ${await r.text()}`);
  const j = await r.json();
  return j.access_token;
}

// ---- a raw select against a table, as a given session (or anon) ---------
// Returns { status, rows } — rows is the parsed array (or null on error).
async function selectAs(token, table, query = 'select=*&limit=2') {
  const headers = { apikey: ANON };
  if (token) headers.Authorization = `Bearer ${token}`;
  const r = await fetch(`${URL}/rest/v1/${table}?${query}`, { headers });
  let rows = null;
  try { rows = await r.json(); } catch { rows = null; }
  return { status: r.status, rows: Array.isArray(rows) ? rows : rows };
}

// ---- enumerate the live table list --------------------------------------
async function liveTableList() {
  // Preferred: authoritative list via helper RPC using service role.
  if (SERVICE) {
    const r = await fetch(`${URL}/rest/v1/rpc/list_public_tables`, {
      method: 'POST',
      headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'content-type': 'application/json' },
      body: '{}',
    });
    if (r.ok) {
      const j = await r.json();
      if (Array.isArray(j) && j.length) return j.map(x => x.table_name || x);
    }
    console.warn('list_public_tables RPC unavailable; falling back to OpenAPI. (Create it from the companion SQL for an authoritative list.)');
  }
  // Fallback: tables PostgREST exposes in its OpenAPI document.
  const r = await fetch(`${URL}/rest/v1/`, { headers: { apikey: ANON, Accept: 'application/openapi+json' } });
  const spec = await r.json();
  const paths = Object.keys(spec.paths || {});
  return paths.filter(p => p.startsWith('/') && p.length > 1 && !p.includes('{') && p !== '/rpc')
             .map(p => p.slice(1)).filter(p => !p.startsWith('rpc/'));
}

async function main() {
  const A = await signIn(cfg.locumA.email, cfg.locumA.password);
  const B = await signIn(cfg.locumB.email, cfg.locumB.password);
  const P = await signIn(cfg.pharmacyP.email, cfg.pharmacyP.password);
  const Q = await signIn(cfg.pharmacyQ.email, cfg.pharmacyQ.password);

  const tables = await liveTableList();
  results.table_list = tables;
  results.table_list_source = SERVICE ? 'information_schema (service_role)' : 'PostgREST OpenAPI';
  console.log(`\nLive schema exposed ${tables.length} tables. Source: ${results.table_list_source}\n`);

  // 1) anon must be DENIED on every table except explicitly-public ones.
  const PUBLIC_OK = new Set(cfg.public_tables || []); // e.g. ['meteo_cache','fsa_centroides','articles']
  for (const t of tables) {
    const { status, rows } = await selectAs(null, t);
    const returnedData = status === 200 && Array.isArray(rows) && rows.length > 0;
    if (PUBLIC_OK.has(t)) {
      record('anon', t, 'SELECT', 'ALLOWED', returnedData || status === 200 ? 'ALLOWED' : 'DENIED', 'declared public');
    } else {
      // DENIED means: empty result (RLS filtered) or an error status. Data returned = FAIL.
      record('anon', t, 'SELECT', 'DENIED', returnedData ? 'ALLOWED' : 'DENIED', `status ${status}, rows ${Array.isArray(rows) ? rows.length : 'n/a'}`);
    }
  }

  // 2) Locum A tries to read Locum B's specific rows (targeted, by id).
  for (const [table, idField, idVal] of cfg.locumB_owned || []) {
    const { status, rows } = await selectAs(A, table, `${idField}=eq.${idVal}&select=*`);
    const got = status === 200 && Array.isArray(rows) && rows.length > 0;
    record('locumA', `${table}[${idField}=${idVal}] (locumB's)`, 'SELECT', 'DENIED', got ? 'ALLOWED' : 'DENIED', `status ${status}`);
  }

  // 3) Pharmacy P tries to read Pharmacy Q's specific rows.
  for (const [table, idField, idVal] of cfg.pharmacyQ_owned || []) {
    const { status, rows } = await selectAs(P, table, `${idField}=eq.${idVal}&select=*`);
    const got = status === 200 && Array.isArray(rows) && rows.length > 0;
    record('pharmacyP', `${table}[${idField}=${idVal}] (pharmacyQ's)`, 'SELECT', 'DENIED', got ? 'ALLOWED' : 'DENIED', `status ${status}`);
  }

  // 4) Locum A attempts UPDATE on a row it does not own (should affect 0 rows / be denied).
  for (const [table, idField, idVal, patch] of cfg.locumA_forbidden_updates || []) {
    const headers = { apikey: ANON, Authorization: `Bearer ${A}`, 'content-type': 'application/json', Prefer: 'return=representation' };
    const r = await fetch(`${URL}/rest/v1/${table}?${idField}=eq.${idVal}`, { method: 'PATCH', headers, body: JSON.stringify(patch) });
    let rows = null; try { rows = await r.json(); } catch {}
    const changed = r.status < 300 && Array.isArray(rows) && rows.length > 0;
    record('locumA', `${table}[${idField}=${idVal}] (not owned)`, 'UPDATE', 'DENIED', changed ? 'ALLOWED' : 'DENIED', `status ${r.status}`);
  }

  // 5) anon must be DENIED on protected RPCs (SECURITY DEFINER functions).
  //    This is the exact class of the sql/73 leak — anon EXECUTE on an RPC.
  for (const [fn, body] of cfg.protected_rpcs || []) {
    const r = await fetch(`${URL}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: { apikey: ANON, 'content-type': 'application/json' }, body: JSON.stringify(body || {}),
    });
    // 401/403/404 = denied. 200 with data = FAIL (anon executed it).
    const executed = r.status === 200;
    record('anon', `rpc/${fn}`, 'EXECUTE', 'DENIED', executed ? 'ALLOWED' : 'DENIED', `status ${r.status}`);
  }

  results.summary = { passes, fails, total: passes + fails, verdict: fails === 0 ? 'PASS' : 'FAIL' };
  fs.writeFileSync('rls-audit-results.json', JSON.stringify(results, null, 2));
  console.log(`\n==== ${fails === 0 ? 'ALL PASS' : fails + ' FAIL(S)'} — ${passes}/${passes + fails} — results written to rls-audit-results.json ====`);
  process.exit(fails === 0 ? 0 : 1);
}

main().catch(e => { console.error('AUDIT ERROR:', e.message); process.exit(2); });
