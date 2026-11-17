// "Trending now" (owner, 2026-10-10): products gaining momentum across
// Marracat, from first-party signals only.
//
//  - Website: product opens, add to cart and Buy clicks (site_events, already
//    hashed per visitor, owner and crawlers left out when recorded), plus
//    recommendation taps (rec_tap) once those are recorded. Taps on sponsored
//    rows don't count: paid placement is not momentum.
//  - App: orders in synced profiles (each has a date), and how many accounts
//    have a product in their recently viewed or saved lists. Those lists carry
//    no dates, so a once-a-day snapshot of the counts (trending_snapshots)
//    gives them a past to compare against. Only counts per product are kept;
//    no list, account or visitor is ever returned.
//
// A product shows only when at least MIN_PEOPLE different people touched it
// in the window: a few people (or one person on several devices) can't put a
// product on everyone's Home, and nobody's activity can be read off the row.
// The owner's own accounts never count.
//
// Momentum: the last 48 hours' weighted engagement against the 14 days
// before, as a 48-hour rate, smoothed. With too little recent data it falls
// back to "Popular this week" (same rules, no momentum); with too little of
// that, the row is hidden (basis "none").
import { rateLimit } from "express-rate-limit";
import { createHash } from "node:crypto";
import { querySource } from "./catalog.js";
import { isOwnerEmail } from "./owner-metrics.js";
import { localDay } from "./visits.js";

const HOUR = 3_600_000, DAY = 24 * HOUR;
export const RECENT_MS = 48 * HOUR;
export const BASELINE_MS = 14 * DAY;
export const WEEK_MS = 7 * DAY;
export const MIN_PEOPLE = 3;
export const MIN_ROW = 6;
export const LIMIT_MAX = 48;
export const CACHE_MS = 10 * 60_000;
// Buy clicks and orders weigh most; a glance at a product least.
export const WEIGHTS = { product_open: 1, rec_tap: 1, add_to_cart: 3, buy_click: 5, order: 5, viewed: 1, saved: 2 };
const SPONSORED_ROW = /^(sponsored|boost)/i;
const APPLE_EPOCH_MS = 978_307_200_000; // Swift's Date: seconds since 2001-01-01

const sha = (v) => createHash("sha256").update(String(v)).digest("hex");
const CATEGORY = /^[a-z][a-z0-9-]{0,40}$/;

export function installTrendingSchema(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS trending_snapshots (
    day TEXT NOT NULL, product TEXT NOT NULL, viewed INTEGER NOT NULL, saved INTEGER NOT NULL,
    PRIMARY KEY(day, product));
    CREATE TABLE IF NOT EXISTS trending_snapshot_days (day TEXT PRIMARY KEY)`);
}

/// The owner's account ids (their email on the users table).
function ownerIDs(db, env) {
  try {
    return new Set(db.prepare("SELECT id, email FROM users").all().filter((u) => isOwnerEmail(u.email, env)).map((u) => u.id));
  } catch { return new Set(); }
}

const tableExists = (db, name) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);
const hasColumn = (db, table, col) => !!db.prepare(`SELECT 1 FROM pragma_table_info('${table}') WHERE name=?`).get(col);

/// Every synced app profile except the owner's: [{ who, viewed, saved, orders:[{ts, products}] }].
function appProfiles(db, env) {
  if (!tableExists(db, "mobile_profiles")) return [];
  const owners = ownerIDs(db, env);
  const out = [];
  for (const row of db.prepare("SELECT user_id, data FROM mobile_profiles").all()) {
    if (owners.has(row.user_id)) continue;
    let p;
    try { p = JSON.parse(row.data); } catch { continue; }
    if (p?.personalizationEnabled === false) continue; // opted out of personalization: not counted either
    const ids = (list) => (Array.isArray(list) ? list.filter((x) => typeof x === "string").slice(0, 200) : []);
    const orders = (Array.isArray(p?.checkouts) ? p.checkouts : []).slice(0, 200).map((c) => ({
      ts: Number.isFinite(c?.date) ? APPLE_EPOCH_MS + c.date * 1000 : null,
      products: ids(c?.productIDs),
    })).filter((o) => o.ts);
    out.push({ who: "a:" + sha(row.user_id), viewed: ids(p?.recentlyViewed), saved: ids(p?.saved), orders });
  }
  return out;
}

/// Today's per-product counts of accounts that viewed or saved it, written
/// once per local day (later calls the same day refresh it).
export function snapshotProfiles(db, profiles, now = Date.now()) {
  installTrendingSchema(db);
  const day = localDay(now), counts = new Map();
  for (const p of profiles) {
    for (const id of new Set(p.viewed)) counts.set(id, { viewed: (counts.get(id)?.viewed || 0) + 1, saved: counts.get(id)?.saved || 0 });
    for (const id of new Set(p.saved)) counts.set(id, { viewed: counts.get(id)?.viewed || 0, saved: (counts.get(id)?.saved || 0) + 1 });
  }
  const put = db.prepare("INSERT INTO trending_snapshots(day,product,viewed,saved) VALUES(?,?,?,?) ON CONFLICT(day,product) DO UPDATE SET viewed=excluded.viewed, saved=excluded.saved");
  db.transaction(() => {
    db.prepare("DELETE FROM trending_snapshots WHERE day=?").run(day);
    for (const [id, c] of counts) put.run(day, id, c.viewed, c.saved);
    // The day itself, so a day when nobody had anything listed still counts as a zero.
    db.prepare("INSERT OR IGNORE INTO trending_snapshot_days(day) VALUES(?)").run(day);
    // Thirty days is plenty of past for a 14-day baseline.
    db.prepare("DELETE FROM trending_snapshots WHERE day < ?").run(localDay(now - 30 * DAY));
    db.prepare("DELETE FROM trending_snapshot_days WHERE day < ?").run(localDay(now - 30 * DAY));
  })();
  return counts;
}

/// Weighted signals per product in [from, to): { score, people:Set }.
function webSignals(db, from, to) {
  const out = new Map();
  if (!tableExists(db, "site_events")) return out;
  const names = ["product_open", "add_to_cart", "buy_click", "rec_tap"];
  const rowCol = hasColumn(db, "site_events", "row");
  // The app's own events (platform 'ios', /api/events since 2026-10-11) are
  // left out: app shoppers are counted from their profiles below, and their
  // device id would let one person count as two toward MIN_PEOPLE.
  const webOnly = hasColumn(db, "site_events", "platform") ? " AND (platform IS NULL OR platform = 'web')" : "";
  const rows = db.prepare(`SELECT name, product, visitor${rowCol ? ", row" : ""} FROM site_events
    WHERE ts >= ? AND ts < ? AND product IS NOT NULL AND name IN (${names.map(() => "?").join(",")})${webOnly}`).all(from, to, ...names);
  for (const r of rows) {
    if (rowCol && r.row && SPONSORED_ROW.test(r.row)) continue;
    const s = out.get(r.product) || { score: 0, people: new Set() };
    s.score += WEIGHTS[r.name] || 0;
    s.people.add("w:" + r.visitor);
    out.set(r.product, s);
  }
  return out;
}

function merge(into, from) {
  for (const [id, s] of from) {
    const t = into.get(id) || { score: 0, people: new Set() };
    t.score += s.score;
    for (const p of s.people) t.people.add(p);
    into.set(id, t);
  }
  return into;
}

function orderSignals(profiles, from, to) {
  const out = new Map();
  for (const p of profiles) for (const o of p.orders) {
    if (o.ts < from || o.ts >= to) continue;
    for (const id of new Set(o.products)) {
      const s = out.get(id) || { score: 0, people: new Set() };
      s.score += WEIGHTS.order;
      s.people.add(p.who);
      out.set(id, s);
    }
  }
  return out;
}

/// App viewed/saved lists as of now: who has each product.
function listSignals(profiles) {
  const out = new Map();
  for (const p of profiles) {
    for (const [list, w] of [[p.viewed, WEIGHTS.viewed], [p.saved, WEIGHTS.saved]]) for (const id of new Set(list)) {
      const s = out.get(id) || { score: 0, people: new Set() };
      s.score += w;
      s.people.add(p.who);
      out.set(id, s);
    }
  }
  return out;
}

/// How much more of each product's list counts there are today than the
/// average day before (from the snapshots), as weighted engagement.
function listGrowth(db, todayCounts, now) {
  const out = new Map();
  const since = localDay(now - BASELINE_MS), today = localDay(now);
  const past = db.prepare(`SELECT product, AVG(viewed) v, AVG(saved) s, COUNT(*) days FROM trending_snapshots
    WHERE day >= ? AND day < ? GROUP BY product`).all(since, today);
  const days = db.prepare("SELECT COUNT(*) n FROM trending_snapshot_days WHERE day >= ? AND day < ?").get(since, today).n;
  if (!days) return out; // no past yet: lists can't show momentum
  const before = new Map(past.map((r) => [r.product, r]));
  for (const [id, c] of todayCounts) {
    const b = before.get(id);
    // A product missing from a past day's snapshot had zero that day.
    const v = b ? (b.v * b.days) / days : 0, s = b ? (b.s * b.days) / days : 0;
    const grew = Math.max(0, c.viewed - v) * WEIGHTS.viewed + Math.max(0, c.saved - s) * WEIGHTS.saved;
    if (grew > 0) out.set(id, grew);
  }
  return out;
}

// Cards are the very records /api/catalog sends (catalog.js's compact list),
// less their search tags, so the website draws them like every other card.
const card = ({ tags, ...p }) => p;

/// The row: { title, basis: "momentum"|"popular"|"none", products }.
export function computeTrending(db, { now = Date.now(), limit = 24, category = "", products = querySource()?.products || [], env = process.env } = {}) {
  installTrendingSchema(db);
  const byID = new Map(products.map((p) => [p.id, p]));
  const eligible = (id) => {
    const p = byID.get(id);
    // The home page's row: sex toys stay off it, as they do off the home
    // feed (src/catalog.js keptOffHome); a department page's row keeps them.
    return p && p.available && (category ? p.category === category : !(p.subs || []).includes("sexual-wellness"));
  };
  const profiles = appProfiles(db, env);
  const todayCounts = snapshotProfiles(db, profiles, now);
  const lists = listSignals(profiles);

  // Momentum: recent 48 h vs the 14 days before it, as a 48-hour rate.
  const recent = merge(webSignals(db, now - RECENT_MS, now), orderSignals(profiles, now - RECENT_MS, now));
  for (const [id, grew] of listGrowth(db, todayCounts, now)) {
    const s = recent.get(id) || { score: 0, people: new Set() };
    s.score += grew;
    // The people behind list growth are whoever has it listed now.
    for (const who of lists.get(id)?.people || []) s.people.add(who);
    recent.set(id, s);
  }
  const before = merge(webSignals(db, now - RECENT_MS - BASELINE_MS, now - RECENT_MS),
    orderSignals(profiles, now - RECENT_MS - BASELINE_MS, now - RECENT_MS));
  const momentum = [];
  for (const [id, s] of recent) {
    if (s.people.size < MIN_PEOPLE || !eligible(id)) continue;
    const base = (before.get(id)?.score || 0) * (RECENT_MS / BASELINE_MS);
    // Smoothed lift: +2 keeps one stray event from looking like a surge.
    const lift = (s.score + 1) / (base + 2);
    if (s.score >= 3 && lift >= 1.5) momentum.push({ id, rank: s.score * lift });
  }
  momentum.sort((a, b) => b.rank - a.rank || a.id.localeCompare(b.id));
  if (momentum.length >= MIN_ROW)
    return { title: "Trending now", basis: "momentum", products: momentum.slice(0, limit).map((m) => card(byID.get(m.id))) };

  // Popular this week: last 7 days of web + orders, plus today's lists.
  const week = merge(merge(webSignals(db, now - WEEK_MS, now), orderSignals(profiles, now - WEEK_MS, now)), lists);
  const popular = [...week].filter(([id, s]) => s.people.size >= MIN_PEOPLE && eligible(id))
    .map(([id, s]) => ({ id, rank: s.score }))
    .sort((a, b) => b.rank - a.rank || a.id.localeCompare(b.id));
  if (popular.length >= MIN_ROW)
    return { title: "Popular this week", basis: "popular", products: popular.slice(0, limit).map((m) => card(byID.get(m.id))) };
  return { title: "Trending now", basis: "none", products: [] };
}

export function trendingRoutes(app, db, { env = process.env, products = () => querySource()?.products || [], now = () => Date.now() } = {}) {
  installTrendingSchema(db);
  const cache = new Map();
  app.get("/api/trending", rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: "draft-8", legacyHeaders: false }), (req, res) => {
    const n = Number.parseInt(String(req.query.limit ?? "24"), 10);
    const limit = Number.isInteger(n) && n > 0 ? Math.min(n, LIMIT_MAX) : 24;
    const category = String(req.query.category ?? "");
    if (category && !CATEGORY.test(category)) return res.status(400).json({ error: "Invalid category" });
    const key = `${limit}|${category}`, hit = cache.get(key), t = now();
    let body = hit && t - hit.at < CACHE_MS ? hit.body : null;
    if (!body) {
      try {
        body = computeTrending(db, { now: t, limit, category, products: products(), env });
      } catch (e) {
        console.error("Trending failed:", e.name);
        body = { title: "Trending now", basis: "none", products: [] };
      }
      if (cache.size > 200) cache.clear();
      cache.set(key, { at: t, body });
    }
    res.set("Cache-Control", "public, max-age=300");
    res.json(body);
  });
}
