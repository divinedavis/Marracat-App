// One row per visitor per day, for the owner dashboard's returning visitors,
// actives (DAU/WAU/MAU), retention and traffic sources (owner, 2026-10-04:
// "should have the same tiles and metrics that findacrib has"). The server
// log keeps 14 days and has no stable visitor id, so none of those could be
// measured before.
//
// The website sends a random id it keeps in localStorage; the app sends its
// install key (X-Marracat-Device, the same one restock alerts use). Only a
// SHA-256 of either is stored, with the platform, build and, for a visitor's
// first visit, where they came from. No IP address, no user agent.
import express from "express";
import { createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { isDatacenter } from "./datacenter.js";

const sha = (v) => createHash("sha256").update(v).digest("hex");
const ID = /^[A-Za-z0-9_-]{16,128}$/;

export function installVisitSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS visits (
      day TEXT NOT NULL, visitor TEXT NOT NULL, platform TEXT NOT NULL,
      build TEXT, channel TEXT, ref_host TEXT, src TEXT, first INTEGER NOT NULL DEFAULT 0,
      user_id TEXT, PRIMARY KEY (day, visitor));
    CREATE INDEX IF NOT EXISTS visits_visitor ON visits(visitor);`);
}

// Visitors we know (owner, 2026-11-09: "mark the person who looked on styl
// charm as our content creator", and "i think this person searching pants and
// fog is me"). Keyed by the same hashed id visits and site_events store, so a
// label never holds a raw id or an address. kind 'owner' is the owner's own
// browser or phone: nothing it sends is recorded. kind 'creator' is a creator
// we work with: still counted, but named in the report so their demo shopping
// isn't read as a stranger's. Add one with server/label-visitor.js.
export const LABEL_KINDS = ["owner", "creator"];
export function installLabelSchema(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS visitor_labels (
      visitor TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('owner','creator')),
      name TEXT NOT NULL DEFAULT '', added TEXT NOT NULL)`);
}
/// The label for a raw visitor id (as sent), or null.
export function labelOf(db, rawVisitor) {
  return db.prepare("SELECT kind, name FROM visitor_labels WHERE visitor=?").get(sha(String(rawVisitor || ""))) ?? null;
}
export const isOwnerVisitor = (db, rawVisitor) => labelOf(db, rawVisitor)?.kind === "owner";
/// Label a stored (hashed) visitor. An owner label also removes what that
/// visitor already left in visits and site_events.
export function labelVisitor(db, hashed, kind, name = "", now = Date.now()) {
  if (!/^[a-f0-9]{64}$/.test(String(hashed))) throw new Error("visitor must be the 64-character stored hash");
  if (!LABEL_KINDS.includes(kind)) throw new Error(`kind must be one of ${LABEL_KINDS.join(", ")}`);
  installLabelSchema(db);
  const removed = { visits: 0, site_events: 0 };
  db.transaction(() => {
    db.prepare(`INSERT INTO visitor_labels(visitor,kind,name,added) VALUES(?,?,?,?)
        ON CONFLICT(visitor) DO UPDATE SET kind=excluded.kind, name=excluded.name`)
      .run(hashed, kind, String(name).slice(0, 80), localDay(now));
    if (kind !== "owner") return;
    for (const t of Object.keys(removed))
      if (db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t))
        removed[t] = db.prepare(`DELETE FROM ${t} WHERE visitor=?`).run(hashed).changes;
  })();
  return removed;
}

/// Whether an address is one the owner's signed-in devices used today (UTC
/// day, as owner-metrics.js stores it).
export function ownerIPToday(db, ip, now = Date.now()) {
  try {
    return !!db.prepare("SELECT 1 FROM owner_sightings WHERE day=? AND ip=?").get(new Date(now).toISOString().slice(0, 10), ip);
  } catch {
    return false;  // no owner_sightings table yet
  }
}

/// The referring site's host, or "" for none or our own pages.
export function refHost(ref) {
  try {
    const h = new URL(String(ref)).hostname.toLowerCase().replace(/^www\./, "");
    return h === "marracat.com" || h.endsWith(".marracat.com") ? "" : h.slice(0, 120);
  } catch {
    return "";
  }
}

/// The local (New York) day of a timestamp, as the dashboard cuts ranges.
export function localDay(ms) {
  return new Date(ms).toLocaleDateString("en-CA", { timeZone: "America/New_York" });
}

// Browsers that aren't people: crawlers, headless Chrome, and the user agents
// our own Playwright journeys run under (2026-10-13: a live run against
// marracat.com counted as ~20 visitors). Playwright's iPhone devices claim
// "iPhone OS 17_5" with a Safari "Version/26": no real iPhone sends that
// pair. The app-prompt / app-banner journeys use iOS 18.0 Safari and Chrome
// 129 for iOS; real iOS 18.0 visitors are rare by now, and losing them from
// the count is the price of the suite never counting.
export const NOT_A_PERSON = /bot|crawl|spider|headless|preview|lighthouse|slurp|facebookexternalhit|playwright/i;
export const TEST_DEVICE_UA =
  /iPhone OS 17_5 like Mac OS X.*Version\/2\d|iPhone OS 18_0 like Mac OS X.*(CriOS\/129\.0 Mobile\/15E148|Version\/18\.0 Mobile\/15E148)/;
export const notAPerson = (ua) => NOT_A_PERSON.test(String(ua || "")) || TEST_DEVICE_UA.test(String(ua || ""));

export function recordVisit(db, { visitor, platform, build = null, channel = null, ref = "", src = "", userID = null, now = Date.now() }) {
  const v = sha(visitor);
  const first = db.prepare("SELECT 1 FROM visits WHERE visitor=? LIMIT 1").get(v) ? 0 : 1;
  db.prepare(`INSERT INTO visits(day,visitor,platform,build,channel,ref_host,src,first,user_id) VALUES(?,?,?,?,?,?,?,?,?)
              ON CONFLICT(day,visitor) DO UPDATE SET user_id=COALESCE(excluded.user_id, visits.user_id)`)
    .run(localDay(now), v, platform, build, channel, first ? refHost(ref) : null, first ? String(src || "").slice(0, 60) : null, first, userID);
}

/// The /24 (IPv4) or /64 (IPv6) an address sits in.
export function netOf(ip) {
  const a = String(ip || "").replace(/^::ffff:/, "");
  if (a.includes(".")) return a.split(".").slice(0, 3).join(".");
  return a.split(":").slice(0, 4).join(":");
}

// A bot farm: one network block showing up as FARM_IPS or more addresses with
// the same browser on one day. On 2026-10-24 Leaseweb (AS7203,
// 152.163.232.0/22) opened one page from each of ~47 addresses with an old
// Linux Chrome, ran our script and read as most of the day's visitors. A
// household or office doesn't rotate through five addresses a day. When a
// block crosses the line, the visits it already left that day are removed
// too. Kept in memory: a restart forgets, and the dashboard's log-based count
// applies the same rule (web/metrics/marracat_metrics.py FARM_IPS). One watcher
// serves /api/visit and /api/events, so a farm's page views leave the event
// report as well (2026-10-29: 205.188.100.0/24 read as 35 of 41 web people
// there while the visit count already refused it).
//
// A block that has been a farm is remembered on disk (farm_blocks: the /24
// and a hash of the browser string, never an address) and refused from its
// first request for FARM_MEMORY_DAYS after it was last seen. Until 2026-11-04
// the watcher lived only in memory, and every deploy let each farm block back
// in for four addresses before it re-crossed the line: 22 restarts on 11/3–4
// left 66 of the week's 95 "web people" as farm page views.
export const FARM_IPS = 5;
export const FARM_MEMORY_DAYS = 30;
export function installFarmSchema(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS farm_blocks (
      net TEXT NOT NULL, ua TEXT NOT NULL, first_day TEXT NOT NULL, last_day TEXT NOT NULL,
      PRIMARY KEY (net, ua))`);
}
export function farmWatch(db) {
  installFarmSchema(db);
  const known = db.prepare("SELECT 1 FROM farm_blocks WHERE net=? AND ua=? AND last_day>=?");
  const remember = db.prepare(`INSERT INTO farm_blocks(net,ua,first_day,last_day) VALUES(?,?,?,?)
      ON CONFLICT(net,ua) DO UPDATE SET last_day=excluded.last_day`);
  let day = null;
  const blocks = new Map();
  return (ip, ua, visitor, now = Date.now()) => {
    const d = localDay(now);
    if (d !== day) { day = d; blocks.clear(); }
    const net = netOf(ip), uaHash = sha(String(ua || ""));
    const key = `${net}|${uaHash}`;
    const b = blocks.get(key) || { ips: new Set(), visitors: new Set(), farm: false };
    blocks.set(key, b);
    b.ips.add(String(ip)); b.visitors.add(sha(visitor));
    if (b.farm) return true;
    if (b.ips.size < FARM_IPS && !known.get(net, uaHash, localDay(now - FARM_MEMORY_DAYS * 86_400_000))) return false;
    b.farm = true;
    remember.run(net, uaHash, d, d);
    const del = ["visits", "site_events"]
      .filter((t) => db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t))
      .map((t) => db.prepare(`DELETE FROM ${t} WHERE day=? AND visitor=? AND platform='web'`));
    db.transaction(() => { for (const v of b.visitors) for (const q of del) q.run(d, v); })();
    return true;
  };
}

export function visitRoutes(app, db, { viewer = async () => null, isFarm = farmWatch(db) } = {}) {
  installVisitSchema(db);
  installLabelSchema(db);
  app.post("/api/visit", rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }),
    express.json({ limit: "2kb" }), async (req, res) => {
      const ua = req.get("User-Agent") || "";
      const app = /^Marracat\/(\d+)/.exec(ua);
      const visitor = app ? req.get("X-Marracat-Device") : req.body?.id;
      if (!ID.test(String(visitor || ""))) return res.sendStatus(400);
      // Crawlers run scripts too; they aren't visitors.
      if (!app && notAPerson(ua)) return res.sendStatus(204);
      // A browser on a server network is a crawler that runs scripts too.
      if (!app && isDatacenter(req.ip)) return res.sendStatus(204);
      if (!app && isFarm(req.ip, ua, String(visitor))) return res.sendStatus(204);
      // The owner's own browser or phone, by label or by today's address
      // (2026-11-09: the owner's Mac browsed signed out and read as a
      // returning web visitor).
      if (isOwnerVisitor(db, visitor) || ownerIPToday(db, req.ip)) return res.sendStatus(204);
      const channel = app ? (/channel\/(\w+)/.exec(ua)?.[1] || null) : null;
      const user = await viewer(req).catch(() => null);
      recordVisit(db, {
        visitor: String(visitor), platform: app ? "ios" : "web", build: app ? app[1] : null, channel,
        ref: req.body?.ref, src: req.body?.src, userID: user?.id || null,
      });
      res.sendStatus(204);
    });
}
