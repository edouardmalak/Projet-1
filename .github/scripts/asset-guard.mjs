#!/usr/bin/env node
// =====================================================================
// C-Direct — CI asset guard (Task 1.3)
// ---------------------------------------------------------------------
// Cloudflare Pages serves the ENTIRE repo except dot-folders. The ONLY
// thing keeping internal files private is functions/_middleware.js. This
// guard fails the build if any *deployable* file that matches a sensitive
// pattern is NOT covered by a middleware block rule — so a future commit
// can never re-introduce the /media/911/ class of leak (an internal doc
// that ships to the edge, protected by nothing).
//
// "Deployable" = tracked file whose path has NO segment starting with '.'
// (dot-folders like .internal/ and .github/ are never deployed by Pages).
//
// The block rules are PARSED from _middleware.js so this guard and the
// runtime filter can never drift apart.
// =====================================================================
import { execSync } from 'node:child_process';
import fs from 'node:fs';

const mw = fs.readFileSync('functions/_middleware.js', 'utf8');
function arr(name) {
  const m = mw.match(new RegExp(name + '\\s*=\\s*\\[([\\s\\S]*?)\\]'));
  if (!m) return [];
  return [...m[1].matchAll(/'([^']+)'/g)].map(x => x[1].toLowerCase());
}
const prefixes   = arr('PREFIXES_BLOQUES');
const extensions = arr('EXTENSIONS_BLOQUEES');
const filePrefix = arr('PREFIXES_FICHIERS_BLOQUES');

// A path (leading slash, lowercased) is protected by the middleware if…
function isBlocked(p) {
  return prefixes.some(x => p.startsWith(x))
      || extensions.some(x => p.endsWith(x))
      || filePrefix.some(x => p.startsWith(x));
}

// Sensitive = must never ship unprotected.
function isSensitive(path) {
  const base = path.split('/').pop().toLowerCase();
  const p = path.toLowerCase();
  if (base.startsWith('.env')) return true;
  if (base.includes('handoff')) return true;
  if (/\.(sql|md|toml|lock|zip)$/.test(base)) return true;
  const internalPrefixes = ['c-direct-actions-','c-direct-audit-','c-direct-scenarios-','phase-test-report','rapport-test-'];
  if (internalPrefixes.some(x => base.startsWith(x))) return true;
  return false;
}

const tracked = execSync('git ls-files', { encoding: 'utf8' }).split('\n').filter(Boolean);
const deployable = tracked.filter(f => !f.split('/').some(seg => seg.startsWith('.')));

const leaks = [];
for (const f of deployable) {
  if (isSensitive(f) && !isBlocked('/' + f.toLowerCase())) leaks.push(f);
}

if (leaks.length) {
  console.error('❌ ASSET GUARD FAILED — these sensitive files would ship UNPROTECTED:');
  for (const f of leaks) console.error('   • ' + f);
  console.error('\nFix: move the file into a dot-folder (e.g. .internal/, never deployed),');
  console.error('or add a matching rule to functions/_middleware.js.');
  process.exit(1);
}
console.log(`✅ Asset guard passed — ${deployable.length} deployable files, no unprotected internal docs.`);
