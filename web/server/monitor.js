// Monitoring for the owner dashboard's Monitor page (owner, 2026-11-15:
// "a real time dashboard for monitoring user journeys, errors, etc. … what
// apis get requests, what buttons get touched, latency, error rate trends …
// separate mobile from web"). Splunk-like, on our own box, no third party.
//
// Two streams, kept in their own SQLite file (monitor.sqlite) so the shop's
// database stays small, plus the app's screens and actions read from the
// events log it already sends (appEvents):
//   requests  every request this server answers: route pattern, status,
//             time to answer, web / ios / bot, app build. Written by
//             monitorMiddleware(), batched every 2 s.
//   client    what the website and the app report (POST /api/monitor): taps,
//             screens, API calls as the shopper saw them (with latency and
//             status), and errors (script errors, failed requests).
// Journeys are anonymous (owner, 2026-11-15): a visitor is an HMAC of the
// website's random id or the app's install id, shown as a short code. No
// IP, email, name, query string or typed text is stored. The owner's own
// traffic is kept but flagged, and the page hides it by default.
//
// Raw rows are kept 30 days; hourly totals per route / tap / error a year.
// The dashboard reads it through GET /api/owner/monitor with the metrics key.

import express from "express";
import Database from "better-sqlite3";
import path from "node:path";
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { isOwnerEmail } from "./owner-metrics.js";
import { isOwnerVisitor, localDay, notAPerson, ownerIPToday } from "./visits.js";

export const KEEP_RAW_DAYS = 30;
export const KEEP_HOURLY_DAYS = 400;
export const KINDS = ["tap", "screen", "api", "error"];
export const PLATFORMS = ["web", "ios", "bot"];
export const RANGES = { "15m": 15 * 60e3, "1h": 3600e3, "6h": 6 * 3600e3, "24h": 86400e3, "7d": 7 * 86400e3,
  "30d": 30 * 86400e3, "90d": 90 * 86400e3, "1y": 365 * 86400e3 };
const RAW_MAX_MS = 86400e3;          // longer ranges read the hourly totals
export const BATCH_MAX = 100;
const APP_UA = /^Marracat\//;
const VISITOR = /^[A-Za-z0-9_-]{16,128}$/;
const SESSION = /^[A-Za-z0-9_-]{6,40}$/;
const METHODS = new Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]);

const digest = (v) => createHash("sha256").update(String(v)).digest();

// ---------- cleaning ----------

/// Text that may be shown on the page: no emails, no long digit runs (order
/// or card numbers), no query strings, one line, capped.
export function cleanText(s, max = 120) {
  if (typeof s !== "string") return null;
  let t = s.replace(/\s+/g, " ").trim();
  t = t.replace(/https?:\/\/[^\s?#]+[?#][^\s]*/g, (u) => u.replace(/[?#].*$/, ""));
  t = t.replace(/[^\s@]+@[^\s@]+\.[^\s@]+/g, "…@…").replace(/\d[\d\s-]{5,}\d/g, "…");
  if (!t) return null;
  return t.length > max ? t.slice(0, max - 1) + "…" : t;
}

/// A path as a route pattern: ids, long tokens and numbers become :id, and
/// the query string goes, so "/api/products/gently-soap-5832925544600?x=1"
/// and its neighbours count as one route.
export function routeOf(p) {
  if (typeof p !== "string") return null;
  let s = p.split(/[?#]/)[0];
  try { if (/^https?:\/\//.test(s)) s = new URL(s).pathname; } catch { return null; }
  if (!s.startsWith("/")) return null;
  const parts = s.split("/").map((seg) => {
    if (!seg) return seg;
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(seg) || /\d{4,}/.test(seg) || seg.length > 32 || /[:,%@]/.test(seg)) return ":id";
    return seg;
  });
  const r = parts.join("/").replace(/\/{2,}/g, "/");
  return r.length > 120 ? r.slice(0, 120) : r;
}

export function platformOf(ua) {
  if (APP_UA.test(ua || "")) return "ios";
  if (notAPerson(ua || "")) return "bot";
  return "web";
}

const num = (v, lo, hi) => (typeof v === "number" && Number.isFinite(v) && v >= lo && v <= hi ? v : null);

/// One client row, or null when it isn't one we take.
export function cleanClient(e, offsetMs = 0) {
  if (!e || typeof e !== "object" || !KINDS.includes(e.k)) return null;
  const row = { kind: e.k, name: null, screen: null, method: null, status: null, ms: null, message: null, offset: offsetMs };
  if (typeof e.sc === "string" && /^[a-z0-9_:/-]{1,40}$/i.test(e.sc)) row.screen = e.sc.toLowerCase();
  if (e.k === "tap") {
    row.name = cleanText(e.n, 80);
    if (!row.name) return null;
  } else if (e.k === "screen") {
    row.name = row.screen || (typeof e.n === "string" && /^[a-z0-9_:/-]{1,40}$/i.test(e.n) ? e.n.toLowerCase() : null);
    if (!row.name) return null;
    row.screen = row.name;
  } else if (e.k === "api") {
    row.name = routeOf(e.n);
    if (!row.name) return null;
    row.method = METHODS.has(String(e.m || "GET").toUpperCase()) ? String(e.m || "GET").toUpperCase() : "GET";
    row.status = num(e.st, 0, 599);
    row.ms = num(e.ms, 0, 120000);
    if (row.status === 0 || (row.status ?? 0) >= 500) row.message = cleanText(e.msg, 200);
  } else if (e.k === "error") {
    row.message = cleanText(e.msg, 200);
    if (!row.message) return null;
    row.name = cleanText(e.n, 80) || "error";       // the error's kind: js, promise, network, decode …
  }
  return row;
}

// ---------- storage ----------

export function openMonitor(dir) {
  const db = new Database(path.join(dir, "monitor.sqlite"));
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  installMonitorSchema(db);
  return db;
}

export function installMonitorSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS requests (ts INTEGER NOT NULL, platform TEXT NOT NULL, method TEXT NOT NULL, route TEXT NOT NULL,
      status INTEGER NOT NULL, ms REAL NOT NULL, build TEXT, owner INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS requests_ts ON requests(ts);
    CREATE TABLE IF NOT EXISTS client (ts INTEGER NOT NULL, platform TEXT NOT NULL, visitor TEXT NOT NULL, session TEXT,
      kind TEXT NOT NULL, name TEXT, screen TEXT, method TEXT, status INTEGER, ms REAL, message TEXT, build TEXT,
      owner INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS client_ts ON client(ts);
    CREATE INDEX IF NOT EXISTS client_visitor ON client(visitor, ts);
    CREATE TABLE IF NOT EXISTS hourly (hour INTEGER NOT NULL, platform TEXT NOT NULL, src TEXT NOT NULL, key TEXT NOT NULL,
      n INTEGER NOT NULL, errors INTEGER NOT NULL, p50 REAL, p95 REAL, visitors INTEGER, PRIMARY KEY(hour, platform, src, key));
  `);
}

/// A writer that batches rows and flushes every `everyMs`, or at 300 rows.
export function batcher(db, { everyMs = 2000 } = {}) {
  const insReq = db.prepare("INSERT INTO requests(ts,platform,method,route,status,ms,build,owner) VALUES(?,?,?,?,?,?,?,?)");
  const insCli = db.prepare(`INSERT INTO client(ts,platform,visitor,session,kind,name,screen,method,status,ms,message,build,owner)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`);
  let reqs = [], clis = [];
  const flush = db.transaction(() => {
    for (const r of reqs) insReq.run(r.ts, r.platform, r.method, r.route, r.status, r.ms, r.build, r.owner ? 1 : 0);
    for (const c of clis) insCli.run(c.ts, c.platform, c.visitor, c.session, c.kind, c.name, c.screen, c.method, c.status, c.ms,
      c.message, c.build, c.owner ? 1 : 0);
    reqs = []; clis = [];
  });
  const run = () => { if (reqs.length || clis.length) { try { flush(); } catch (e) { console.error("monitor flush failed:", e.name); reqs = []; clis = []; } } };
  const timer = setInterval(run, everyMs); timer.unref?.();
  return {
    request(r) { reqs.push(r); if (reqs.length >= 300) run(); },
    client(c) { clis.push(c); if (clis.length >= 300) run(); },
    flush: run,
    stop() { clearInterval(timer); run(); },
  };
}

// ---------- the request log ----------

/// Times every request Express answers. Static files nginx serves never get here.
export function monitorMiddleware(write, { ownerIP = () => false } = {}) {
  return (req, res, next) => {
    const start = process.hrtime.bigint();
    res.on("finish", () => {
      try {
        const p = req.originalUrl || req.url || "";
        // Its own beacons, the dashboard's questions and uptime checks aren't shopper traffic.
        if (/^\/api\/(monitor|owner\/|health\b)/.test(p)) return;
        if (/\.(js|css|png|jpe?g|svg|ico|webp|woff2?|map|txt|xml|json)$/i.test(p.split("?")[0]) && !p.startsWith("/api/")) return;
        const ua = req.get("User-Agent") || "";
        const routePath = req.route?.path && typeof req.route.path === "string" ? (req.baseUrl || "") + req.route.path : null;
        const route = routePath ? routeOf(routePath) : routeOf(p);
        if (!route) return;
        write.request({
          ts: Date.now(), platform: platformOf(ua), method: req.method, route, status: res.statusCode,
          ms: Math.round(Number(process.hrtime.bigint() - start) / 1e4) / 100,
          build: ua.match(/^Marracat\/(\d{1,6})\b/)?.[1] ?? null, owner: ownerIP(req.ip),
        });
      } catch { /* never let monitoring break a response */ }
    });
    next();
  };
}

// ---------- rollups and pruning ----------

function pct(sorted, p) {
  if (!sorted.length) return null;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1));
  return Math.round(sorted[i] * 10) / 10;
}

/// Hourly totals for one finished hour, owner left out. Safe to run twice.
export function rollupHour(db, hourStart) {
  const end = hourStart + 3600e3;
  const up = db.prepare(`INSERT OR REPLACE INTO hourly(hour,platform,src,key,n,errors,p50,p95,visitors) VALUES(?,?,?,?,?,?,?,?,?)`);
  const groups = new Map();
  const add = (platform, src, key, ms, err, visitor) => {
    const k = platform + "\u0000" + src + "\u0000" + key;
    let g = groups.get(k);
    if (!g) groups.set(k, g = { platform, src, key, n: 0, errors: 0, ms: [], visitors: new Set() });
    g.n++; if (err) g.errors++; if (ms != null) g.ms.push(ms); if (visitor) g.visitors.add(visitor);
  };
  for (const r of db.prepare("SELECT platform, method, route, status, ms FROM requests WHERE ts>=? AND ts<? AND owner=0").iterate(hourStart, end))
    add(r.platform, "req", r.method + " " + r.route, r.ms, r.status >= 500);
  for (const c of db.prepare("SELECT platform, visitor, kind, name, method, status, ms, message FROM client WHERE ts>=? AND ts<? AND owner=0").iterate(hourStart, end)) {
    if (c.kind === "api") add(c.platform, "capi", c.method + " " + c.name, c.ms, c.status === 0 || c.status >= 500, c.visitor);
    else if (c.kind === "error") add(c.platform, "error", c.message, null, true, c.visitor);
    else add(c.platform, c.kind, c.kind === "tap" ? (c.screen ? c.screen + " › " : "") + c.name : c.name, null, false, c.visitor);
    add(c.platform, "visit", "*", null, false, c.visitor);
  }
  db.transaction(() => {
    for (const g of groups.values()) {
      g.ms.sort((a, b) => a - b);
      up.run(hourStart, g.platform, g.src, g.key, g.n, g.errors, pct(g.ms, 0.5), pct(g.ms, 0.95), g.visitors.size || null);
    }
  })();
  return groups.size;
}

export function pruneMonitor(db, now = Date.now()) {
  const raw = now - KEEP_RAW_DAYS * 86400e3;
  db.prepare("DELETE FROM requests WHERE ts<?").run(raw);
  db.prepare("DELETE FROM client WHERE ts<?").run(raw);
  db.prepare("DELETE FROM hourly WHERE hour<?").run(now - KEEP_HOURLY_DAYS * 86400e3);
}

/// Roll up every finished hour since the last one written (at most two days back).
export function catchUpRollups(db, now = Date.now()) {
  const thisHour = Math.floor(now / 3600e3) * 3600e3;
  const last = db.prepare("SELECT MAX(hour) h FROM hourly").get().h;
  let h = Math.max(last != null ? last + 3600e3 : thisHour - 48 * 3600e3, thisHour - 48 * 3600e3);
  let n = 0;
  for (; h < thisHour; h += 3600e3) { rollupHour(db, h); n++; }
  return n;
}

// ---------- reading it back ----------

const STATUS_CLASS = { "2xx": [200, 299], "3xx": [300, 399], "4xx": [400, 499], "5xx": [500, 599] };

function filters(q, table) {
  const where = [], args = [];
  if (q.platform && PLATFORMS.includes(q.platform)) { where.push("platform=?"); args.push(q.platform); }
  else if (q.platform !== "all-bots") { where.push("platform<>'bot'"); }
  if (q.owner !== "1") where.push("owner=0");
  if (q.build && /^\d{1,6}$/.test(q.build)) { where.push("build=?"); args.push(q.build); }
  if (q.status && STATUS_CLASS[q.status]) {
    where.push(table === "client" ? "kind='api' AND status BETWEEN ? AND ?" : "status BETWEEN ? AND ?");
    args.push(...STATUS_CLASS[q.status]);
  }
  if (q.route) {
    if (table === "requests") { where.push("(method || ' ' || route)=? OR route=?"); args.push(q.route, q.route); }
    else { where.push("((method || ' ' || name)=? OR name=?)"); args.push(q.route, q.route); }
  }
  if (table === "client" && q.kind && KINDS.includes(q.kind)) { where.push("kind=?"); args.push(q.kind); }
  if (table === "client" && q.screen && /^[a-z0-9_:/-]{1,40}$/i.test(q.screen)) { where.push("screen=?"); args.push(q.screen); }
  if (q.q) {
    const like = "%" + String(q.q).slice(0, 80).replace(/[%_]/g, "") + "%";
    if (table === "requests") { where.push("route LIKE ?"); args.push(like); }
    else { where.push("(name LIKE ? OR message LIKE ? OR screen LIKE ?)"); args.push(like, like, like); }
  }
  if (q.visitor && /^[a-f0-9]{6,16}$/.test(q.visitor)) {
    if (table === "requests") where.push("0");
    else { where.push("visitor LIKE ?"); args.push(q.visitor + "%"); }
  }
  return { sql: where.length ? " AND " + where.map((w) => "(" + w + ")").join(" AND ") : "", args };
}

function bucketFor(span) {
  if (span <= 15 * 60e3) return 30e3;
  if (span <= 3600e3) return 60e3;
  if (span <= 6 * 3600e3) return 5 * 60e3;
  if (span <= 86400e3) return 15 * 60e3;
  if (span <= 7 * 86400e3) return 3600e3;
  if (span <= 30 * 86400e3) return 6 * 3600e3;
  return 86400e3;
}

const stat = (ms) => { ms.sort((a, b) => a - b); return { p50: pct(ms, 0.5), p95: pct(ms, 0.95) }; };

// The app already reports its screens and actions to the events log
// (server/events.js, site_events, platform "ios"), so its taps, screens and
// journeys show here without a new build. Owner traffic never reaches that
// log. A visitor there is its own hash, shown as a code like any other.
const APP_SKIP = new Set(["rec_view", "banner_view", "session_end", "app_open", "product_view", "visit"]);
const human = (n) => n.replace(/_/g, " ").replace(/^./, (c) => c.toUpperCase());
// The website's own events log rows count too, but only from before the
// website's monitor started (webSince), so nothing is counted twice: the
// visits from before monitoring existed still show (owner, 2026-11-15: "we
// had a user on the site a few hours ago").
export function appEvents(mainDb, since, q = {}, { limit = 20000, until = Infinity, order = "ASC", webSince = 0 } = {}) {
  if (!mainDb || (q.platform && !["ios", "web"].includes(q.platform)) || q.route || q.status || (q.kind && !["tap", "screen"].includes(q.kind))) return [];
  try {
    const plat = q.platform === "ios" ? "platform='ios'" : q.platform === "web" ? "(COALESCE(platform,'web')='web' AND ts<?)"
      : "(platform='ios' OR (COALESCE(platform,'web')='web' AND ts<?))";
    const where = ["day>=?", "ts>=?", "ts<=?", plat], args = [localDay(since), since, until === Infinity ? 9e15 : until];
    if (q.platform !== "ios") args.push(webSince || 0);
    if (q.build && /^\d{1,6}$/.test(q.build)) { where.push("build=?"); args.push(q.build); }
    if (q.visitor && /^[a-f0-9]{6,16}$/.test(q.visitor)) { where.push("visitor LIKE ?"); args.push(q.visitor + "%"); }
    const rows = mainDb.prepare(`SELECT ts, COALESCE(platform,'web') platform, substr(visitor,1,16) visitor, name, row, build, brand,
      json_extract(props,'$.screen') screen
      FROM site_events WHERE ${where.join(" AND ")} ORDER BY ts ${order === "DESC" ? "DESC" : "ASC"} LIMIT ?`).all(...args, limit);
    const like = q.q ? String(q.q).toLowerCase() : null;
    return rows.filter((r) => !APP_SKIP.has(r.name)).map((r) => r.name === "screen_view"
      ? { ts: r.ts, platform: r.platform, visitor: r.visitor, kind: "screen", name: r.screen || "screen", screen: r.screen || null, build: r.build }
      : { ts: r.ts, platform: r.platform, visitor: r.visitor, kind: "tap", screen: null, build: r.build,
          name: human(r.name) + (r.row ? " · " + r.row : r.brand && /^(buy_click|checkout_|add_to_cart|brand_)/.test(r.name) ? " · " + r.brand : "") })
      .filter((r) => (!q.kind || r.kind === q.kind) && (!q.screen || r.screen === q.screen) && (!like || (r.name || "").toLowerCase().includes(like)));
  } catch { return []; }
}

/// When the website's own monitor began sending (its first client row).
export function webSince(db) {
  try { return db.prepare("SELECT MIN(ts) t FROM client WHERE platform='web'").get().t ?? Date.now(); } catch { return Date.now(); }
}

/// The Monitor page's main view.
export function overview(db, q, now = Date.now(), mainDb = null) {
  const span = RANGES[q.range] || RANGES["1h"];
  const since = now - span, bucket = bucketFor(span);
  const nb = Math.ceil(span / bucket), start = Math.floor(since / bucket) * bucket;
  const empty = () => ({ n: 0, err: 0, ms: [] });
  const series = Array.from({ length: nb + 1 }, (_, i) => ({ t: start + i * bucket, web: empty(), ios: empty(), bot: empty() }));
  const slot = (ts) => series[Math.min(series.length - 1, Math.max(0, Math.floor((ts - start) / bucket)))];
  const routes = new Map(), taps = new Map(), screens = new Map(), errs = new Map(), capi = new Map();
  const visitors = new Set(), sessions = new Set();
  let tapN = 0, clientErr = 0, reqN = 0, reqErr = 0, allMs = [];
  const bump = (m, key, f) => { let g = m.get(key); if (!g) m.set(key, g = f()); return g; };
  const builds = new Set();

  if (span <= RAW_MAX_MS) {
    const rf = filters(q, "requests");
    for (const r of db.prepare(`SELECT ts, platform, method, route, status, ms, build FROM requests WHERE ts>=?${rf.sql}`).iterate(since, ...rf.args)) {
      const s = slot(r.ts)[r.platform]; const err = r.status >= 500;
      s.n++; if (err) s.err++; s.ms.push(r.ms);
      reqN++; if (err) reqErr++; allMs.push(r.ms);
      const g = bump(routes, r.method + " " + r.route, () => ({ route: r.method + " " + r.route, n: 0, errors: 0, s4: 0, ms: [], web: 0, ios: 0 }));
      g.n++; if (err) g.errors++; if (r.status >= 400 && r.status < 500) g.s4++; g.ms.push(r.ms); if (r.platform !== "bot") g[r.platform]++;
      if (r.build) builds.add(r.build);
    }
    const cf = filters(q, "client");
    for (const c of db.prepare(`SELECT ts, platform, visitor, session, kind, name, screen, method, status, ms, message, build FROM client WHERE ts>=?${cf.sql}`).iterate(since, ...cf.args)) {
      visitors.add(c.visitor); if (c.session) sessions.add(c.session); if (c.build) builds.add(c.build);
      if (c.kind === "tap") {
        tapN++;
        const g = bump(taps, (c.screen || "") + "\u0000" + c.name, () => ({ name: c.name, screen: c.screen, n: 0, v: new Set(), web: 0, ios: 0 }));
        g.n++; g.v.add(c.visitor); g[c.platform] = (g[c.platform] || 0) + 1;
      } else if (c.kind === "screen") {
        const g = bump(screens, c.name, () => ({ screen: c.name, n: 0, v: new Set() })); g.n++; g.v.add(c.visitor);
      } else if (c.kind === "api") {
        const err = c.status === 0 || c.status >= 500;
        const g = bump(capi, c.method + " " + c.name, () => ({ route: c.method + " " + c.name, n: 0, errors: 0, ms: [] }));
        g.n++; if (err) g.errors++; if (c.ms != null) g.ms.push(c.ms);
        if (err) { clientErr++; const e = bump(errs, "api\u0000" + c.method + " " + c.name, () => ({ source: "client", kind: "failed request", message: (c.method + " " + c.name + (c.status ? " → " + c.status : " → no response")), n: 0, last: 0, platforms: new Set(), v: new Set() }));
          e.n++; e.last = Math.max(e.last, c.ts); e.platforms.add(c.platform); e.v.add(c.visitor); }
      } else if (c.kind === "error") {
        clientErr++;
        const e = bump(errs, "err\u0000" + c.message, () => ({ source: "client", kind: c.name, message: c.message, n: 0, last: 0, platforms: new Set(), v: new Set() }));
        e.n++; e.last = Math.max(e.last, c.ts); e.platforms.add(c.platform); e.v.add(c.visitor);
      }
    }
    for (const g of routes.values()) if (g.errors) {
      const e = bump(errs, "srv\u0000" + g.route, () => ({ source: "server", kind: "5xx", message: g.route + " answered 5xx", n: 0, last: 0, platforms: new Set(), v: new Set() }));
      e.n += g.errors;
    }
  } else {
    // Long ranges: the hourly totals (owner already left out).
    const plat = q.platform && PLATFORMS.includes(q.platform) ? q.platform : null;
    const rows = db.prepare(`SELECT * FROM hourly WHERE hour>=?${plat ? " AND platform=?" : " AND platform<>'bot'"}`).all(since, ...(plat ? [plat] : []));
    const like = q.q ? String(q.q).toLowerCase() : null;
    for (const h of rows) {
      if (like && !h.key.toLowerCase().includes(like)) continue;
      if (q.route && h.key !== q.route) continue;
      if (h.src === "req") {
        const s = slot(h.hour)[h.platform]; s.n += h.n; s.err += h.errors; if (h.p50 != null) s.ms.push(h.p50);
        s.p95s = (s.p95s || []); if (h.p95 != null) s.p95s.push(h.p95);
        reqN += h.n; reqErr += h.errors; if (h.p50 != null) allMs.push(h.p50);
        const g = bump(routes, h.key, () => ({ route: h.key, n: 0, errors: 0, s4: 0, ms: [], p95s: [], web: 0, ios: 0 }));
        g.n += h.n; g.errors += h.errors; if (h.p50 != null) g.ms.push(h.p50); if (h.p95 != null) g.p95s.push(h.p95); if (h.platform !== "bot") g[h.platform] += h.n;
      } else if (h.src === "tap") {
        tapN += h.n; const [screen, name] = h.key.includes(" › ") ? h.key.split(" › ") : [null, h.key];
        const g = bump(taps, h.key, () => ({ name, screen, n: 0, v: new Set(), vn: 0, web: 0, ios: 0 })); g.n += h.n; g.vn += h.visitors || 0; g[h.platform] = (g[h.platform] || 0) + h.n;
      } else if (h.src === "screen") {
        const g = bump(screens, h.key, () => ({ screen: h.key, n: 0, v: new Set(), vn: 0 })); g.n += h.n; g.vn += h.visitors || 0;
      } else if (h.src === "capi") {
        const g = bump(capi, h.key, () => ({ route: h.key, n: 0, errors: 0, ms: [] })); g.n += h.n; g.errors += h.errors; if (h.p50 != null) g.ms.push(h.p50);
        clientErr += h.errors;
      } else if (h.src === "error") {
        clientErr += h.n;
        const e = bump(errs, "err\u0000" + h.key, () => ({ source: "client", kind: "error", message: h.key, n: 0, last: 0, platforms: new Set(), v: new Set(), vn: 0 }));
        e.n += h.n; e.last = Math.max(e.last, h.hour + 3600e3); e.platforms.add(h.platform); e.vn += h.visitors || 0;
      } else if (h.src === "visit") {
        visitors.add(h.hour + h.platform); // a count, not people: hourly visitors add up across hours
      }
    }
  }

  for (const a of appEvents(mainDb, since, q, { webSince: webSince(db) })) {
    if (span <= RAW_MAX_MS) visitors.add(a.platform + ":" + a.visitor);
    if (a.build) builds.add(a.build);
    if (a.kind === "tap") {
      tapN++;
      const g = bump(taps, "\u0000" + a.name, () => ({ name: a.name, screen: null, n: 0, v: new Set(), web: 0, ios: 0 }));
      g.n++; g.v.add(a.visitor); g[a.platform] = (g[a.platform] || 0) + 1;
    } else {
      const g = bump(screens, a.name, () => ({ screen: a.name, n: 0, v: new Set() })); g.n++; g.v.add(a.platform + ":" + a.visitor);
    }
  }
  const out = (g) => { const st = stat(g.ms); return { ...st, p95: g.p95s ? stat(g.p95s).p95 ?? st.p95 : st.p95 }; };
  const sortN = (a, b) => b.n - a.n;
  allMs.sort((a, b) => a - b);
  return {
    range: q.range in RANGES ? q.range : "1h", since, until: now, bucket_ms: bucket, source: span <= RAW_MAX_MS ? "raw" : "hourly",
    kpis: {
      requests: reqN, server_errors: reqErr, error_rate: reqN ? Math.round((reqErr / reqN) * 10000) / 100 : 0,
      p50: pct(allMs, 0.5), p95: pct(allMs, 0.95),
      visitors: span <= RAW_MAX_MS ? visitors.size : null, sessions: span <= RAW_MAX_MS ? sessions.size : null,
      taps: tapN, client_errors: clientErr,
    },
    series: series.map((s) => Object.fromEntries([["t", s.t], ...["web", "ios", "bot"].map((p) => {
      const x = s[p]; const st = out(x);
      return [p, { n: x.n, err: x.err, p50: st.p50, p95: st.p95 }];
    })])),
    routes: [...routes.values()].sort(sortN).slice(0, 40).map((g) => ({ route: g.route, n: g.n, errors: g.errors, s4: g.s4 || 0,
      error_rate: g.n ? Math.round((g.errors / g.n) * 10000) / 100 : 0, web: g.web, ios: g.ios, ...out(g) })),
    client_routes: [...capi.values()].sort(sortN).slice(0, 25).map((g) => ({ route: g.route, n: g.n, errors: g.errors, ...out(g) })),
    taps: [...taps.values()].sort(sortN).slice(0, 40).map((g) => ({ name: g.name, screen: g.screen, n: g.n, visitors: g.vn ?? g.v.size, web: g.web || 0, ios: g.ios || 0 })),
    screens: [...screens.values()].sort(sortN).slice(0, 25).map((g) => ({ screen: g.screen, n: g.n, visitors: g.vn ?? g.v.size })),
    errors: [...errs.values()].sort(sortN).slice(0, 40).map((e) => ({ source: e.source, kind: e.kind, message: e.message, n: e.n,
      last: e.last || null, platforms: [...e.platforms], visitors: e.vn ?? e.v.size })),
    builds: [...builds].sort((a, b) => Number(b) - Number(a)).slice(0, 15),
  };
}

/// The live tail: newest first, both streams merged.
export function stream(db, q, now = Date.now(), limit = 200, mainDb = null) {
  const span = Math.min(RANGES[q.range] || RANGES["1h"], RAW_MAX_MS * 30);
  const since = Math.max(now - span, Number(q.after) || 0);
  const rf = filters(q, "requests"), cf = filters(q, "client");
  const reqs = q.kind && q.kind !== "request" ? [] : db.prepare(`SELECT ts, platform, method, route, status, ms, build, owner FROM requests WHERE ts>?${rf.sql}
    ORDER BY ts DESC LIMIT ?`).all(since, ...rf.args, limit).map((r) => ({ src: "server", kind: "request", ...r, name: r.route }));
  const clis = q.kind === "request" ? [] : db.prepare(`SELECT ts, platform, substr(visitor,1,8) visitor, substr(session,1,8) session, kind, name, screen, method, status, ms, message, build, owner
    FROM client WHERE ts>?${cf.sql} ORDER BY ts DESC LIMIT ?`).all(since, ...cf.args, limit).map((c) => ({ src: "client", ...c }));
  const app = q.kind === "request" ? [] : appEvents(mainDb, since, q, { limit, order: "DESC", webSince: webSince(db) })
    .map((a) => ({ src: "app", ...a, visitor: a.visitor.slice(0, 8), owner: 0 }));
  return { rows: [...reqs, ...clis, ...app].sort((a, b) => b.ts - a.ts).slice(0, limit), until: now };
}

/// One visitor's journey: their client rows in order, split into sessions.
export function journey(db, visitor, q = {}, now = Date.now(), mainDb = null) {
  if (!/^[a-f0-9]{6,16}$/.test(visitor || "")) return { visitor: null, sessions: [] };
  const since = now - KEEP_RAW_DAYS * 86400e3;
  let rows = db.prepare(`SELECT ts, platform, session, kind, name, screen, method, status, ms, message, build FROM client
    WHERE visitor LIKE ? AND ts>=? ${q.owner === "1" ? "" : "AND owner=0"} ORDER BY ts LIMIT 2000`).all(visitor + "%", since);
  // An app visitor's code comes from the events log (see appEvents).
  if (!rows.length) rows = appEvents(mainDb, since, { visitor }, { limit: 2000, webSince: webSince(db) }).map((a) => ({ ...a, session: null }));
  const sessions = [];
  for (const r of rows) {
    const key = r.session || "—";
    let s = sessions[sessions.length - 1];
    if (!s || s.session !== key || r.ts - s.end > 30 * 60e3) sessions.push(s = { session: key, start: r.ts, end: r.ts, platform: r.platform, build: r.build, rows: [] });
    s.end = r.ts; s.rows.push(r);
  }
  return { visitor, sessions: sessions.reverse().slice(0, 30) };
}

// ---------- routes ----------

export function monitorRoutes(app, mainDb, mdb, write, { viewer = async () => null, appViewer = () => null, env = process.env, isDatacenter = () => false } = {}) {
  const salt = env.EVENTS_SALT || env.AUTH_SECRET || "monitor";
  const hashV = (v) => createHmac("sha256", salt).update("monitor:" + v).digest("hex").slice(0, 16);
  const perIP = new Map(); let minute = 0;
  const budget = (ip, n) => {
    const m = Math.floor(Date.now() / 60e3); if (m !== minute) { perIP.clear(); minute = m; }
    const t = (perIP.get(ip) || 0) + n; if (t > 1500) return false; perIP.set(ip, t); return true;
  };

  app.post("/api/monitor", rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }),
    express.json({ limit: "32kb", type: () => true }), async (req, res) => {
      const ua = req.get("User-Agent") || "";
      if (notAPerson(ua)) return res.sendStatus(204);
      const fromApp = APP_UA.test(ua);
      if (!fromApp && isDatacenter(req.ip)) return res.sendStatus(204);
      const body = req.body || {};
      const list = Array.isArray(body.ev) ? body.ev : [];
      if (!list.length || list.length > BATCH_MAX) return res.sendStatus(400);
      const raw = String((fromApp ? req.get("X-Marracat-Device") : body.id) ?? "");
      if (!VISITOR.test(raw)) return res.sendStatus(400);
      if (!budget(req.ip || "?", list.length)) return res.sendStatus(429);
      const now = Date.now();
      const clientNow = num(body.now, 0, 1e14);
      const rows = list.map((e) => {
        const off = clientNow != null && num(e.t, 0, 1e14) != null ? Math.min(600000, Math.max(0, clientNow - e.t)) : 0;
        return cleanClient(e, off);
      }).filter(Boolean);
      if (!rows.length) return res.sendStatus(400);
      const user = fromApp ? (() => { try { return appViewer(req); } catch { return null; } })() : await viewer(req).catch(() => null);
      const ownerVisitor = (() => { try { return isOwnerVisitor(mainDb, raw); } catch { return false; } })();
      const owner = (user && isOwnerEmail(user.email, env)) || ownerVisitor || ownerIPToday(mainDb, req.ip)
        || (fromApp && /\bchannel\/debug\b/.test(ua)) || (!fromApp && body.o === 1);
      const build = fromApp ? ua.match(/^Marracat\/(\d{1,6})\b/)?.[1] ?? null
        : (typeof body.b === "string" && /^\d{1,6}$/.test(body.b) ? body.b : null);
      const visitor = hashV(raw);
      const session = typeof body.s === "string" && SESSION.test(body.s) ? hashV("s:" + body.s).slice(0, 12) : null;
      const platform = fromApp ? "ios" : "web";
      for (const r of rows) write.client({ ts: now - r.offset, platform, visitor, session, kind: r.kind, name: r.name, screen: r.screen,
        method: r.method, status: r.status, ms: r.ms, message: r.message, build, owner });
      res.sendStatus(204);
    });

  app.get("/api/owner/monitor", (req, res) => {
    res.set("Cache-Control", "no-store");
    const key = env.METRICS_KEY || "";
    const given = req.get("X-Metrics-Key") || "";
    if (key.length < 32 || !timingSafeEqual(digest(key), digest(given))) return res.sendStatus(404);
    write.flush();
    const q = Object.fromEntries(Object.entries(req.query).filter(([, v]) => typeof v === "string"));
    const view = q.view || "overview";
    try {
      if (view === "stream") return res.json(stream(mdb, q, Date.now(), 200, mainDb));
      if (view === "journey") return res.json(journey(mdb, q.visitor, q, Date.now(), mainDb));
      return res.json(overview(mdb, q, Date.now(), mainDb));
    } catch (e) {
      console.error("monitor query failed:", e.message);
      return res.status(500).json({ error: "query_failed" });
    }
  });

  // Hourly totals for finished hours, and the 30-day / 1-year trims.
  const hourly = () => { try { catchUpRollups(mdb); pruneMonitor(mdb); } catch (e) { console.error("monitor rollup failed:", e.message); } };
  setTimeout(hourly, 20_000).unref?.();
  setInterval(hourly, 10 * 60e3).unref?.();
}
