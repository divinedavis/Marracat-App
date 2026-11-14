// How fast the website was for the people actually using it (owner,
// 2026-11-10: "real-visitor speed metrics"). The page watches the browser's
// own timings (src/vitals.js) and sends them once, as it is left.
//
// Kept apart from site_events on purpose: every page load sends one, and a row
// per load there would make every visitor look like someone who did something.
// No visitor id, no address, no user agent: a row is a day, the kind of page,
// and each timing as a range ("1500-2500" ms), never the number itself.
import express from "express";
import { rateLimit } from "express-rate-limit";
import { bucket, SCREENS } from "./events.js";
import { localDay } from "./visits.js";

export const KEEP_DAYS = 90;
// Range edges in milliseconds. The middle edges are the published "good" and
// "poor" lines for each measure (web.dev/vitals), so the report can say how
// many loads were good without storing an exact time.
export const EDGES = {
  ttfb: [200, 800, 1800],
  fcp: [1000, 1800, 3000, 5000],
  lcp: [1500, 2500, 4000, 6000, 10000],
  inp: [100, 200, 500, 1000],
  // Seconds until the whole catalog could be searched on the device.
  catalog: [1, 2, 4, 8, 15, 30],
};
// Layout shift is a score, not a time.
export const CLS_EDGES = [0.1, 0.25];
/// At or under this a measure is "good": [good, poor] per measure.
export const LINES = { ttfb: [800, 1800], fcp: [1800, 3000], lcp: [2500, 4000], inp: [200, 500], cls: [0.1, 0.25], catalog: [4, 15] };
export const CATALOG_FROM = ["device", "network", "page"];
export const CONNECTIONS = ["slow-2g", "2g", "3g", "4g"];
const MEASURES = ["ttfb", "fcp", "lcp", "inp", "cls", "catalog"];

export function installVitalsSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS web_vitals (
      id INTEGER PRIMARY KEY, day TEXT NOT NULL, screen TEXT, ttfb TEXT, fcp TEXT, lcp TEXT, inp TEXT, cls TEXT,
      catalog TEXT, catalog_from TEXT, conn TEXT, installed INTEGER NOT NULL DEFAULT 0, repeat INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS web_vitals_day ON web_vitals(day);`);
}

/// One page load's timings, cleaned; null when nothing usable was sent.
export function cleanVitals(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const ms = (k) => bucket(body[k], EDGES[k]);
  const row = {
    screen: SCREENS.includes(body.screen) ? body.screen : null,
    ttfb: ms("ttfb") ?? null, fcp: ms("fcp") ?? null, lcp: ms("lcp") ?? null, inp: ms("inp") ?? null,
    cls: bucket(body.cls, CLS_EDGES) ?? null,
    catalog: ms("catalog") ?? null,
    catalog_from: CATALOG_FROM.includes(body.catalog_from) ? body.catalog_from : null,
    conn: CONNECTIONS.includes(body.conn) ? body.conn : null,
    installed: body.installed === true ? 1 : 0,
    repeat: body.repeat === true ? 1 : 0,
  };
  return MEASURES.some((m) => row[m]) ? row : null;
}

export function recordVitals(db, row, now = Date.now()) {
  db.prepare(`INSERT INTO web_vitals (day, screen, ttfb, fcp, lcp, inp, cls, catalog, catalog_from, conn, installed, repeat)
    VALUES (@day, @screen, @ttfb, @fcp, @lcp, @inp, @cls, @catalog, @catalog_from, @conn, @installed, @repeat)`).run({ ...row, day: localDay(now) });
}

/// A range's upper edge ("1500-2500" -> 2500); the open top range has none.
const upper = (range) => (range.endsWith("+") ? Infinity : Number(range.split("-")[1]));

/// Per measure: loads counted, and the share good and poor (a range counts
/// as good when all of it is at or under the good line).
export function vitalsReport(db, { days = 7, now = Date.now() } = {}) {
  const since = localDay(now - (days - 1) * 86_400_000);
  const out = { loads: db.prepare("SELECT COUNT(*) n FROM web_vitals WHERE day >= ?").get(since).n, measures: {} };
  for (const m of MEASURES) {
    const rows = db.prepare(`SELECT ${m} range, COUNT(*) n FROM web_vitals WHERE day >= ? AND ${m} IS NOT NULL GROUP BY ${m}`).all(since);
    const n = rows.reduce((a, r) => a + r.n, 0);
    if (!n) continue;
    const [good, poor] = LINES[m];
    const share = (test) => Math.round((100 * rows.filter((r) => test(upper(r.range))).reduce((a, r) => a + r.n, 0)) / n);
    out.measures[m] = { loads: n, good_pct: share((u) => u <= good), poor_pct: share((u) => u > poor),
      ranges: Object.fromEntries(rows.sort((a, b) => upper(a.range) - upper(b.range)).map((r) => [r.range, r.n])) };
  }
  out.catalog_from = Object.fromEntries(db.prepare(`SELECT catalog_from k, COUNT(*) n FROM web_vitals
    WHERE day >= ? AND catalog_from IS NOT NULL GROUP BY catalog_from`).all(since).map((r) => [r.k, r.n]));
  const flags = db.prepare("SELECT SUM(installed) installed, SUM(repeat) repeat FROM web_vitals WHERE day >= ?").get(since);
  out.installed = flags.installed || 0;
  out.repeat = flags.repeat || 0;
  return out;
}

export function vitalsRoutes(app, db) {
  installVitalsSchema(db);
  db.prepare("DELETE FROM web_vitals WHERE day < ?").run(localDay(Date.now() - KEEP_DAYS * 86_400_000));
  app.post("/api/vitals",
    rateLimit({ windowMs: 60_000, limit: 20, standardHeaders: "draft-8", legacyHeaders: false }),
    // sendBeacon posts a Blob; its type is ours, but read any small body as JSON.
    express.json({ limit: "2kb", type: () => true }),
    (req, res) => {
      const row = cleanVitals(req.body);
      if (row) recordVitals(db, row);
      res.sendStatus(204);
    });
}
