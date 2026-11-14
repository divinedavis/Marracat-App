// Weekly input for "learn from failed searches" (owner, 2026-10-10): every web
// search over the last N days, grouped by what was typed, with how often it
// found nothing. catalog/search_gaps.py runs this over ssh on the droplet,
//
//   DATA_DIR=/var/lib/marracat node server/search-gaps.js --days 7
//
// and decides which ones need a synonym and which are kinds of products
// Marracat doesn't carry. It opens the database read-only and prints JSON;
// it never writes. Searches that look like an email address or a phone or
// card number are left out, and only the query text and counts leave.
//
// App searches come in through /api/events as site_events rows with platform
// 'ios'; `source` says which platforms a query came from ("web", "ios" or
// "ios+web").
import Database from "better-sqlite3";
import path from "node:path";
import { pathToFileURL } from "node:url";

const DAY = 86_400_000;
const PERSONAL = /@|\d[\d\s().-]{6,}\d/;

/// Query text that is safe to keep: trimmed, bounded, and not personal data.
export function cleanQuery(q) {
  const s = String(q || "").replace(/\s+/g, " ").trim().toLowerCase();
  if (s.length < 2 || s.length > 80 || PERSONAL.test(s)) return null;
  return s;
}

export function collect(db, { days = 7, now = Date.now() } = {}) {
  const since = now - days * DAY;
  const has = db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='site_events'").get();
  // App searches arrive through /api/events too (platform 'ios', since
  // 2026-10-11); each group says which platforms it came from.
  const platform = has && db.prepare("SELECT 1 FROM pragma_table_info('site_events') WHERE name='platform'").get();
  const rows = has
    ? db.prepare(`SELECT q, n, visitor${platform ? ", platform" : ""} FROM site_events
        WHERE name='search' AND ts >= ? AND q IS NOT NULL`).all(since)
    : [];
  const byQuery = new Map();
  for (const r of rows) {
    const q = cleanQuery(r.q);
    if (!q) continue;
    const g = byQuery.get(q) || { q, searches: 0, zero: 0, visitors: new Set(), results: [], sources: new Set() };
    g.searches += 1;
    g.sources.add(r.platform === "ios" ? "ios" : "web");
    if (r.n === 0) g.zero += 1;
    if (Number.isInteger(r.n)) g.results.push(r.n);
    g.visitors.add(r.visitor);
    byQuery.set(q, g);
  }
  const queries = [...byQuery.values()]
    .map((g) => ({
      q: g.q, searches: g.searches, zero: g.zero, visitors: g.visitors.size, source: [...g.sources].sort().join("+"),
      // The typical result count, so "weak" searches (a handful of hits) show too.
      median_results: g.results.length ? g.results.sort((a, b) => a - b)[Math.floor(g.results.length / 2)] : null,
    }))
    .sort((a, b) => b.searches - a.searches || a.q.localeCompare(b.q));
  return { generated_at: new Date(now).toISOString(), days, queries };
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  const i = process.argv.indexOf("--days");
  const days = Math.min(Math.max(Number(i > -1 ? process.argv[i + 1] : 7) || 7, 1), 180);
  const dataDir = process.env.DATA_DIR || "/var/lib/marracat";
  const db = new Database(path.join(dataDir, "marracat.sqlite"), { readonly: true, fileMustExist: true });
  process.stdout.write(JSON.stringify(collect(db, { days })) + "\n");
  db.close();
}
