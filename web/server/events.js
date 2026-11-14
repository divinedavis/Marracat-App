// What shoppers do on the website and in the iPhone app, counted on our own
// server (owner, 2026-10-10: "start counting what visitors do", then "are we
// detecting everything a user is doing on the app? … make our analytics more
// robust"). Search, browsing, saves, alerts and the Buy click all happen on the
// device, so the server log never saw them; this is the record the weekly
// report reads (events-report.js). The event catalog is server/EVENTS.md.
//
// First party only: no third-party script, no new cookie. The website sends
// the random visitor id its visit count keeps (localStorage); the app sends
// X-Marracat-Device. Both are stored only as a SHA-256. A signed-in shopper is
// stored as a salted hash of the account id (so per-person funnels work), never
// the id, an email, a name or an address. Every event has a strict schema:
// ids must match their pattern, strings are capped, numbers like a session's
// length or a cart's subtotal are bucketed here, and any prop not in the
// schema is dropped. Free text is only ever a search query, and a query that
// looks like an email or a long number isn't kept. The owner's own browsing
// and phone, and crawlers, are left out. Rows older than 180 days go.
import express from "express";
import { createHash, createHmac } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { isOwnerEmail } from "./owner-metrics.js";
import { isDatacenter } from "./datacenter.js";
import { farmWatch, installLabelSchema, installVisitSchema, isOwnerVisitor, localDay, notAPerson, ownerIPToday, recordVisit } from "./visits.js";

const sha = (v) => createHash("sha256").update(v).digest("hex");
const VISITOR = /^[A-Za-z0-9_-]{16,128}$/;
const PRODUCT = /^[\w.-]{1,160}$/;
const BRAND = /^[a-z0-9][a-z0-9-]{0,79}$/i;
const SLUG = /^[a-z0-9][a-z0-9_-]{0,79}$/i;
const TYPE = /^[a-z0-9_-]{1,40}:[a-z0-9_-]{1,40}$/i;
const BUILD = /^[0-9]{1,6}$/;
export const ROW = /^[a-z][a-z0-9_:-]{0,40}$/;
export const PLATFORMS = ["ios", "web"];
export const BATCH_MAX = 50;
// Events one address may store a minute, however they're batched.
export const EVENTS_PER_MINUTE = 900;
export const KEEP_DAYS = 180;
const APP_UA = /^Marracat\//;

// How a Buy click leaves: a Shopify cart link, Big Cartel's cart page, a Swell
// checkout, the filled-in checkout built for several brands, or the brand's own
// product page.
export const BUY_VIA = ["cart", "bigcartel", "swell", "checkout", "brand_site"];
// How a checkout starts: those, plus the app's Buy Now sheet and the
// "review all checkouts" page.
export const CHECKOUT_VIA = [...BUY_VIA, "buy_now", "review", "ucp"];
export const SCREENS = ["home", "search", "browse", "aisle", "brand", "product", "cart", "checkout_review", "orders",
  "order_detail", "account", "saved", "lists", "alerts", "social", "boosts"];
export const BOOLEAN_FILTERS = ["in_stock", "sale", "under_25", "clean", "metal", "scent", "safer", "food", "baby",
  "fiber", "fabric", "lab", "pet", "material", "home"];
export const FILTERS = [...BOOLEAN_FILTERS, "sort", "brand", "type", "aisle", "category"];
export const SORTS = ["featured", "low", "high", "new"];
export const ALERT_KINDS = ["restock", "price", "brand_sale", "brand_drops", "interest"];
export const PROVIDERS = ["apple", "google", "email", "passkey"];
export const SHARE_KINDS = ["product", "brand", "list", "app", "profile", "aisle"];
export const SEARCH_SOURCES = ["typed", "suggestion", "recent"];
// Promo banners: the app's search screen "Featured" premier-brand banner.
export const BANNER_KINDS = ["featured_banner"];

// Buckets, so no exact durations or amounts are stored.
export const DURATION_EDGES = [10, 30, 60, 180, 600, 1800, 3600];
export const DWELL_EDGES = [3, 10, 30, 60, 180];
export const SUBTOTAL_EDGES = [25, 50, 100, 250, 500];
/// Shipping the brand's checkout quoted, in dollars: 0-1 is free shipping.
export const SHIPPING_EDGES = [1, 5, 10, 15, 25];
/// How far a brand's checkout got before it closed (owner, 2026-11-08: "lets
/// find which step"), from Checkout Kit's standard pixel events: "opened" =
/// the sheet opened and its page never reported loading.
export const CHECKOUT_STEPS = ["opened", "started", "contact", "address", "shipping", "payment"];
/// Where a sign-in stopped: our server's Apple challenge, the provider's own
/// sheet (cancelled there or it failed), or our exchange of its token for a
/// session.
export const SIGN_IN_STEPS = ["challenge", "provider", "exchange"];
export const SIGN_IN_REASONS = ["cancelled", "error", "network", "server"];
export function bucket(x, edges) {
  if (typeof x !== "number" || !Number.isFinite(x) || x < 0) return undefined;
  let lo = 0;
  for (const e of edges) {
    if (x < e) return `${lo}-${e}`;
    lo = e;
  }
  return `${lo}+`;
}

// Prop validators: each returns the value to keep, or undefined to drop it.
const V = {
  product: (x) => (typeof x === "string" && PRODUCT.test(x) ? x : undefined),
  brand: (x) => (typeof x === "string" && BRAND.test(x) ? x.toLowerCase() : undefined),
  slug: (x) => (typeof x === "string" && SLUG.test(x) ? x.toLowerCase() : undefined),
  row: (x) => (typeof x === "string" && ROW.test(x) ? x : undefined),
  int: (lo, hi) => (x) => (Number.isInteger(x) && x >= lo && x <= hi ? x : undefined),
  oneOf: (list) => (x) => (list.includes(x) ? x : undefined),
  bucket: (edges) => (x) => bucket(x, edges),
  bool: (x) => (typeof x === "boolean" ? x : undefined),
  q: (x) => cleanQuery(x) ?? undefined,
};

/// The event catalog. `required` props must survive validation; everything
/// not listed is dropped. `check` vets props that depend on each other.
export const SCHEMAS = {
  // Website + app: finding things.
  search: { required: ["q"], props: { q: V.q, n: V.int(0, 1_000_000), source: V.oneOf(SEARCH_SOURCES) } },
  product_open: { required: ["product"], props: { product: V.product, brand: V.brand } },
  product_view: { required: ["product"], props: { product: V.product, brand: V.brand, source: V.row, dwell_s: V.bucket(DWELL_EDGES) } },
  screen_view: { required: ["screen"], props: { screen: V.oneOf(SCREENS), brand: V.brand, product: V.product } },
  filter_apply: {
    required: ["filter", "value"],
    props: { filter: V.oneOf(FILTERS), value: (x) => (typeof x === "string" || typeof x === "boolean" ? x : undefined) },
    check: (p) => {
      if (BOOLEAN_FILTERS.includes(p.filter)) p.value = p.value === true || p.value === "on" ? "on" : p.value === false || p.value === "off" ? "off" : undefined;
      else if (p.filter === "sort") p.value = SORTS.includes(p.value) ? p.value : undefined;
      else if (p.filter === "type") p.value = typeof p.value === "string" && TYPE.test(p.value) ? p.value.toLowerCase() : undefined;
      else p.value = typeof p.value === "string" && SLUG.test(p.value) ? p.value.toLowerCase() : undefined;
      return p.value !== undefined;
    },
  },
  // Recommendation rows: shown and tapped.
  rec_view: { required: ["row"], props: { row: V.row, product: V.product, brand: V.brand, position: V.int(0, 999) } },
  rec_tap: { required: ["row"], props: { row: V.row, product: V.product, brand: V.brand, position: V.int(0, 999) } },
  // Banners: shown and tapped.
  banner_view: { required: ["kind", "brand"], props: { kind: V.oneOf(BANNER_KINDS), brand: V.brand } },
  banner_tap: { required: ["kind", "brand"], props: { kind: V.oneOf(BANNER_KINDS), brand: V.brand } },
  // Keeping things.
  save: { required: ["product"], props: { product: V.product, brand: V.brand } },
  unsave: { required: ["product"], props: { product: V.product, brand: V.brand } },
  brand_follow: { required: ["brand"], props: { brand: V.brand } },
  brand_unfollow: { required: ["brand"], props: { brand: V.brand } },
  alert_on: { required: ["kind"], props: { kind: V.oneOf(ALERT_KINDS), product: V.product, brand: V.brand } },
  alert_off: { required: ["kind"], props: { kind: V.oneOf(ALERT_KINDS), product: V.product, brand: V.brand } },
  list_create: { required: [], props: {} },
  list_add: { required: ["product"], props: { product: V.product, brand: V.brand } },
  // Buying.
  add_to_cart: { required: ["product"], props: { product: V.product, brand: V.brand, qty: V.int(1, 99) } },
  remove_from_cart: { required: ["product"], props: { product: V.product, brand: V.brand, qty: V.int(1, 99) } },
  buy_click: { required: ["brand", "via"], props: { brand: V.brand, via: V.oneOf(BUY_VIA), product: V.product } },
  checkout_start: { required: ["via"], props: { brand: V.brand, via: V.oneOf(CHECKOUT_VIA), item_count: V.int(1, 99), subtotal: V.bucket(SUBTOTAL_EDGES) } },
  checkout_complete: { required: ["via"], props: { brand: V.brand, via: V.oneOf(CHECKOUT_VIA), item_count: V.int(1, 99), subtotal: V.bucket(SUBTOTAL_EDGES),
    step: V.oneOf(CHECKOUT_STEPS), shipping: V.bucket(SHIPPING_EDGES) } },
  checkout_abandon: { required: ["via"], props: { brand: V.brand, via: V.oneOf(CHECKOUT_VIA), item_count: V.int(1, 99), subtotal: V.bucket(SUBTOTAL_EDGES),
    step: V.oneOf(CHECKOUT_STEPS), shipping: V.bucket(SHIPPING_EDGES) } },
  // Social and sharing.
  share: { required: ["kind"], props: { kind: V.oneOf(SHARE_KINDS), target: V.product } },
  comment_post: { required: ["product"], props: { product: V.product, brand: V.brand } },
  // The app's life cycle and notifications.
  app_open: { required: [], props: { cold: V.bool } },
  session_end: { required: ["duration_s"], props: { duration_s: V.bucket(DURATION_EDGES) } },
  notification_open: { required: ["kind"], props: { kind: V.row } },
  // Accounts: the provider only.
  sign_in_start: { required: ["provider"], props: { provider: V.oneOf(PROVIDERS) } },
  sign_in_complete: { required: ["provider"], props: { provider: V.oneOf(PROVIDERS) } },
  sign_up_complete: { required: ["provider"], props: { provider: V.oneOf(PROVIDERS) } },
  // Where a sign-in stopped (owner, 2026-11-08): 6 started, 2 finished.
  sign_in_cancel: { required: ["provider"], props: { provider: V.oneOf(PROVIDERS), step: V.oneOf(SIGN_IN_STEPS) } },
  sign_in_fail: { required: ["provider"], props: { provider: V.oneOf(PROVIDERS), step: V.oneOf(SIGN_IN_STEPS), reason: V.oneOf(SIGN_IN_REASONS) } },
  // Looking closer.
  label_sheet_open: { required: ["label"], props: { label: V.row, product: V.product } },
  gallery_open: { required: ["product"], props: { product: V.product } },
  // The brand page's Instagram button (app, 2026-10-17).
  brand_instagram: { required: ["brand"], props: { brand: V.brand } },
  gallery_zoom: { required: ["product"], props: { product: V.product } },
};
export const EVENT_NAMES = Object.keys(SCHEMAS);
export const REC_NAMES = ["rec_view", "rec_tap"];
// Props kept in their own columns (the rest go in `props` as JSON).
const COLUMNS = ["product", "brand", "q", "n", "via", "row", "position"];

/// A search as stored: lower case, spaces collapsed, at most 80 characters.
/// Anything that looks like an email address or a long number (a phone, an
/// order or card number someone pasted) isn't kept at all.
export function cleanQuery(q) {
  const t = String(q ?? "").replace(/\s+/g, " ").trim().toLowerCase().slice(0, 80);
  if (!t || /@/.test(t) || /\d{6,}/.test(t.replace(/[\s-]/g, ""))) return null;
  return t;
}

/// The event to store, or null when it isn't one we take. The website sends
/// the name as `e`, the app as `name`; props may be top level or under `props`.
export function cleanEvent(body, defaultPlatform = "web") {
  if (!body || typeof body !== "object" || Array.isArray(body)) return null;
  const name = String(body.e ?? body.name ?? "");
  const schema = Object.hasOwn(SCHEMAS, name) ? SCHEMAS[name] : null;
  if (!schema) return null;
  const given = body.props && typeof body.props === "object" && !Array.isArray(body.props) ? { ...body, ...body.props } : body;
  const props = {};
  for (const [key, valid] of Object.entries(schema.props)) {
    const v = valid(given[key]);
    if (v !== undefined) props[key] = v;
  }
  if (schema.check && !schema.check(props)) return null;
  if (!schema.required.every((k) => props[k] !== undefined)) return null;
  const platform = PLATFORMS.includes(given.platform) ? given.platform : defaultPlatform;
  const ev = { name, product: null, brand: null, q: null, n: null, via: null, row: null, position: null, platform, props: null };
  const rest = {};
  for (const [k, v] of Object.entries(props)) (COLUMNS.includes(k) ? (ev[k] = v) : (rest[k] = v));
  if (Object.keys(rest).length) ev.props = rest;
  return ev;
}

export function installEventSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS site_events (
      id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, day TEXT NOT NULL, visitor TEXT NOT NULL,
      name TEXT NOT NULL, product TEXT, brand TEXT, q TEXT, n INTEGER, via TEXT);
    CREATE INDEX IF NOT EXISTS site_events_day ON site_events(day, name);
    CREATE INDEX IF NOT EXISTS site_events_product ON site_events(product, name);`);
  // Rows before 2026-10-10 have no platform: they were all the website.
  for (const col of ["row TEXT", "position INTEGER", "platform TEXT", "props TEXT", "build TEXT", "signed_in INTEGER", "user_hash TEXT"])
    if (!db.prepare("SELECT 1 FROM pragma_table_info('site_events') WHERE name=?").get(col.split(" ")[0]))
      db.exec(`ALTER TABLE site_events ADD COLUMN ${col}`);
}

/// `meta`: the app build, whether a shopper was signed in, and the salted hash
/// of their account (userHash) — set by the route, never by the client.
export function recordEvent(db, visitor, ev, now = Date.now(), meta = {}) {
  db.prepare(`INSERT INTO site_events(ts,day,visitor,name,product,brand,q,n,via,row,position,platform,props,build,signed_in,user_hash)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
    .run(now, localDay(now), sha(visitor), ev.name, ev.product, ev.brand, ev.q, ev.n, ev.via,
      ev.row ?? null, ev.position ?? null, ev.platform ?? "web", ev.props ? JSON.stringify(ev.props) : null,
      meta.build ?? null, meta.signedIn ? 1 : 0, meta.userHash ?? null);
}

export function pruneEvents(db, now = Date.now()) {
  return db.prepare("DELETE FROM site_events WHERE ts < ?").run(now - KEEP_DAYS * 86_400_000).changes;
}

/// Counts events per address per minute, so a batch can't multiply what the
/// request limit allows. True when `n` more fit.
export function eventBudget(perMinute = EVENTS_PER_MINUTE, now = Date.now) {
  const used = new Map();
  let window = 0;
  return (key, n) => {
    const minute = Math.floor(now() / 60_000);
    if (minute !== window) { used.clear(); window = minute; }
    const total = (used.get(key) || 0) + n;
    if (total > perMinute) return false;
    used.set(key, total);
    return true;
  };
}

/// A signed-in account as stored: HMAC with a server secret, so the same
/// person links up across events without their id being in the table.
export function userHash(userID, salt) {
  if (!userID || !salt) return null;
  return createHmac("sha256", salt).update("events:" + userID).digest("hex");
}

/// Events the app logs as screens lay out, with no tap behind them.
export const VIEW_ONLY = new Set(["screen_view", "rec_view"]);
/// An app session with no session_end after this long is over (the app was
/// killed in the foreground).
export const SESSION_GAP_MS = 6 * 3_600_000;

/// True when an app batch belongs to a session the shopper opened: it carries
/// app_open, or the device's last open/close was an open in the last six
/// hours. iOS launches the app in the background for the catalog refresh and
/// SwiftUI still lays out Home, so until 2026-11-09 those launches sent a
/// lone Home view and made the phone that day's returning visitor: 45 of 74
/// iPhone visitor-days in two weeks, at all hours, with no app_open. Builds
/// from 2026-11-10 hold those views on the phone; this covers older builds.
export function inAppSession(db, visitor, events, now = Date.now()) {
  if (events.some((e) => e.name === "app_open")) return true;
  const last = db.prepare(`SELECT name FROM site_events WHERE day IN (?, ?) AND name IN ('app_open', 'session_end')
      AND visitor = ? AND ts > ? ORDER BY ts DESC, id DESC LIMIT 1`)
    .get(localDay(now), localDay(now - 86_400_000), sha(visitor), now - SESSION_GAP_MS);
  return last?.name === "app_open";
}

export function eventRoutes(app, db, { viewer = async () => null, appViewer = () => null, env = process.env, limit = 180,
  perMinute = EVENTS_PER_MINUTE, isFarm = farmWatch(db) } = {}) {
  installEventSchema(db);
  installVisitSchema(db);
  pruneEvents(db);
  setInterval(() => pruneEvents(db), 6 * 3_600_000).unref();
  const budget = eventBudget(perMinute);
  const salt = env.EVENTS_SALT || env.AUTH_SECRET || "";
  installLabelSchema(db);
  app.post("/api/events", rateLimit({ windowMs: 60_000, limit, standardHeaders: "draft-8", legacyHeaders: false }),
    // sendBeacon posts a Blob; accept it as JSON whatever type the browser labels it.
    // 24 kB fits a batch of 50 events.
    express.json({ limit: "24kb", type: () => true }), async (req, res) => {
      const ua = req.get("User-Agent") || "";
      if (notAPerson(ua)) return res.sendStatus(204);
      const fromApp = APP_UA.test(ua);
      if (!fromApp && isDatacenter(req.ip)) return res.sendStatus(204);
      // Xcode and simulator builds (channel/debug) are ours: unit tests, UI
      // tests and smoke launches, never a shopper (2026-10-13: a debug
      // install logged 52 list_create in a second from SavedListsTests).
      if (fromApp && /\bchannel\/debug\b/.test(ua)) return res.sendStatus(204);
      const body = req.body;
      const batch = Array.isArray(body?.events);
      if (batch && (body.events.length === 0 || body.events.length > BATCH_MAX)) return res.sendStatus(400);
      let events = (batch ? body.events : [body]).map((e) => cleanEvent(e, fromApp ? "ios" : "web")).filter(Boolean);
      if (!events.length) return res.sendStatus(400);
      // The app is identified by its device header only; the website by its body id.
      const visitor = String((fromApp ? req.get("X-Marracat-Device") : body?.id) ?? "");
      if (!VISITOR.test(visitor)) return res.sendStatus(400);
      // A bot farm (see farmWatch) runs our script on one page per address.
      if (!fromApp && isFarm(req.ip, ua, visitor)) return res.sendStatus(204);
      // Who's signed in comes from the session, never from the body.
      const user = fromApp
        ? (() => { try { return appViewer(req); } catch { return null; } })()
        : await viewer(req).catch(() => null);
      // The owner's own browsing and phone are left out: by account, by a
      // visitor labelled owner, or by an address the owner's signed-in devices
      // used today. Until 2026-11-09 the address rule covered the app only, so
      // the owner's signed-out Mac browser read as a returning web visitor.
      if ((user && isOwnerEmail(user.email, env)) || isOwnerVisitor(db, visitor) || ownerIPToday(db, req.ip))
        return res.sendStatus(204);
      const now = Date.now();
      // A background launch's screen views aren't a visit (inAppSession).
      if (fromApp && !inAppSession(db, visitor, events, now)) {
        events = events.filter((e) => !VIEW_ONLY.has(e.name));
        if (!events.length) return res.sendStatus(204);
      }
      if (!budget(req.ip || "unknown", events.length)) return res.sendStatus(429);
      const build = fromApp ? ua.match(/^Marracat\/(\d{1,6})\b/)?.[1] ?? null
        : (typeof body?.build === "string" && BUILD.test(body.build) ? body.build : null);
      const meta = { build, signedIn: !!user, userHash: user ? userHash(user.id, salt) : null };
      db.transaction(() => {
        for (const ev of events) recordEvent(db, visitor, ev, now, meta);
        // A phone that uses the app is that day's visitor even when its daily
        // ping never went out: VisitPing fires only on a return to the
        // foreground, and on 2026-11-04 six of seven App Store users had screen
        // views but no visit row, so the dashboard's graph read 1 app visitor
        // where the server log saw 9 devices. The website keeps its own ping,
        // which carries the referrer a first visit is credited to.
        if (fromApp) recordVisit(db, { visitor, platform: "ios", build, channel: ua.match(/\bchannel\/(\w+)/)?.[1] ?? null,
          userID: user?.id ?? null, now });
      })();
      res.sendStatus(204);
    });
}

/// Per recommendation row: how often it was shown and tapped, by platform,
/// over the last `days` days.
export function recRowReport(db, { days, now = Date.now() }) {
  const since = localDay(now - (days - 1) * 86_400_000), until = localDay(now);
  return db.prepare(`SELECT row, COALESCE(platform,'web') platform,
      SUM(name='rec_view') views, SUM(name='rec_tap') taps, COUNT(DISTINCT visitor) visitors
      FROM site_events WHERE day BETWEEN ? AND ? AND name IN ('rec_view','rec_tap')
      GROUP BY row, platform ORDER BY views DESC, row`).all(since, until)
    .map((r) => ({ ...r, tap_rate: r.views ? Math.round((r.taps / r.views) * 1000) / 1000 : null }));
}

/// The shopping funnel per platform: opened → viewed a product → added to
/// cart → started a checkout → completed one, in distinct people (visitors).
/// "Opened" is app_open in the app and any event on the website.
export function funnelByPlatform(db, since, until) {
  const count = (platform, names) => db.prepare(`SELECT COUNT(DISTINCT visitor) n FROM site_events
      WHERE day BETWEEN ? AND ? AND COALESCE(platform,'web')=? ${names ? `AND name IN (${names.map(() => "?").join(",")})` : ""}`)
    .get(since, until, platform, ...(names || [])).n;
  return Object.fromEntries(PLATFORMS.map((p) => [p, {
    opened: count(p, p === "ios" ? ["app_open"] : null),
    viewed_a_product: count(p, ["product_view", "product_open"]),
    added_to_cart: count(p, ["add_to_cart"]),
    started_checkout: count(p, ["checkout_start", "buy_click"]),
    completed_checkout: count(p, ["checkout_complete"]),
  }]));
}

/// The weekly report: the funnel by platform, searches, Buy clicks, screens,
/// saves/follows/alerts, sign-ins, notification opens, recommendation rows,
/// and who came back (DAU/WAU, returning, guests vs signed in).
export function eventReport(db, { days = 7, now = Date.now() } = {}) {
  installEventSchema(db);
  const since = localDay(now - (days - 1) * 86_400_000), until = localDay(now);
  const rows = (sql, ...args) => db.prepare(sql).all(since, until, ...args);
  const one = (sql, ...args) => db.prepare(sql).get(since, until, ...args);
  const ALL = "day BETWEEN ? AND ?";
  // The original funnel and searches are the website's; app rows have their own sections.
  const W = "day BETWEEN ? AND ? AND COALESCE(platform,'web')='web'";
  const reached = (name) => one(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE ${W} AND name=?`, name).n;
  const prop = (k) => `json_extract(props,'$.${k}')`;
  const counts = (names) => Object.fromEntries(names.map((n) =>
    [n, one(`SELECT COUNT(*) events, COUNT(DISTINCT visitor) people FROM site_events WHERE ${ALL} AND name=?`, n)]));
  const report = {
    window: { since, until, days },
    funnel_by_platform: funnelByPlatform(db, since, until),
    searches: rows(`SELECT q, COUNT(*) searches, COUNT(DISTINCT visitor) visitors,
        SUM(CASE WHEN n=0 THEN 1 ELSE 0 END) no_results FROM site_events WHERE ${ALL} AND name='search'
        GROUP BY q ORDER BY searches DESC, q LIMIT 25`),
    funnel: {
      visitors_with_any_event: one(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE ${W} AND name NOT IN ('rec_view','rec_tap')`).n,
      searched: reached("search"),
      opened_a_product: reached("product_open"),
      added_to_cart: reached("add_to_cart"),
      clicked_buy: reached("buy_click"),
      events: Object.fromEntries(rows(`SELECT name, COUNT(*) n FROM site_events WHERE ${W} GROUP BY name`).map((r) => [r.name, r.n])),
    },
    buy_clicks_by_brand: rows(`SELECT brand, COUNT(*) clicks, COUNT(DISTINCT visitor) visitors FROM site_events
        WHERE ${ALL} AND name='buy_click' GROUP BY brand ORDER BY clicks DESC LIMIT 15`),
    buy_clicks_by_route: rows(`SELECT via, COUNT(*) clicks FROM site_events WHERE ${ALL} AND name='buy_click' GROUP BY via ORDER BY clicks DESC`),
    products_opened: rows(`SELECT product, COUNT(*) opens, COUNT(DISTINCT visitor) visitors FROM site_events
        WHERE ${ALL} AND name IN ('product_open','product_view') GROUP BY product ORDER BY opens DESC LIMIT 15`),
    top_screens: rows(`SELECT ${prop("screen")} screen, COALESCE(platform,'web') platform, COUNT(*) views, COUNT(DISTINCT visitor) people
        FROM site_events WHERE ${ALL} AND name='screen_view' GROUP BY screen, platform ORDER BY views DESC LIMIT 25`),
    engagement: counts(["save", "unsave", "brand_follow", "brand_unfollow", "alert_on", "alert_off", "list_create", "list_add",
      "share", "comment_post", "gallery_open", "gallery_zoom", "label_sheet_open", "filter_apply", "brand_instagram"]),
    alerts_by_kind: rows(`SELECT ${prop("kind")} kind, SUM(name='alert_on') turned_on, SUM(name='alert_off') turned_off
        FROM site_events WHERE ${ALL} AND name IN ('alert_on','alert_off') GROUP BY kind ORDER BY turned_on DESC`),
    sign_in: rows(`SELECT ${prop("provider")} provider,
        COUNT(DISTINCT CASE WHEN name='sign_in_start' THEN visitor END) started,
        COUNT(DISTINCT CASE WHEN name='sign_in_complete' THEN visitor END) signed_in,
        COUNT(DISTINCT CASE WHEN name='sign_up_complete' THEN visitor END) signed_up
        FROM site_events WHERE ${ALL} AND name IN ('sign_in_start','sign_in_complete','sign_up_complete')
        GROUP BY provider ORDER BY started DESC`),
    notification_opens: rows(`SELECT ${prop("kind")} kind, COUNT(*) opens, COUNT(DISTINCT visitor) people
        FROM site_events WHERE ${ALL} AND name='notification_open' GROUP BY kind ORDER BY opens DESC`),
    banners: rows(`SELECT ${prop("kind")} kind, brand, SUM(name='banner_view') views, SUM(name='banner_tap') taps,
        COUNT(DISTINCT visitor) people FROM site_events WHERE ${ALL} AND name IN ('banner_view','banner_tap')
        GROUP BY kind, brand ORDER BY views DESC, taps DESC LIMIT 25`),
    checkouts: rows(`SELECT name, via, COUNT(*) n, COUNT(DISTINCT visitor) people FROM site_events
        WHERE ${ALL} AND name IN ('checkout_start','checkout_complete','checkout_abandon') GROUP BY name, via ORDER BY name, n DESC`),
    recommendation_rows: { last_7_days: recRowReport(db, { days: 7, now }), last_30_days: recRowReport(db, { days: 30, now }) },
    people: peopleReport(db, { since, until, now }),
    known_people: knownPeople(db, since, until),
  };
  // Recurring visitors from the website's visit count (visits.js).
  try {
    const v = one(`SELECT COUNT(DISTINCT visitor) visitors,
        COUNT(DISTINCT CASE WHEN first=0 THEN visitor END) came_back FROM visits WHERE ${ALL} AND platform='web'`);
    const multi = one(`SELECT COUNT(*) n FROM (SELECT visitor FROM visits WHERE ${ALL} AND platform='web'
        GROUP BY visitor HAVING COUNT(DISTINCT day) > 1)`).n;
    report.visitors = { web_visitors: v.visitors, returning_from_before: v.came_back, came_back_on_2plus_days: multi };
  } catch {
    report.visitors = null;
  }
  return report;
}

/// Labelled visitors (visitor_labels, e.g. a creator) seen in the window, so
/// their activity is read as theirs: days here, last day, and what they did.
export function knownPeople(db, since, until) {
  installLabelSchema(db);
  return db.prepare(`SELECT l.kind, l.name, COUNT(DISTINCT e.day) days, MAX(e.day) last_day,
      SUM(e.name='search') searches, SUM(e.name IN ('product_view','product_open')) product_views,
      SUM(e.name='add_to_cart') added_to_cart, SUM(e.name='checkout_complete') checkouts,
      GROUP_CONCAT(DISTINCT COALESCE(e.platform,'web')) platforms
      FROM visitor_labels l JOIN site_events e ON e.visitor=l.visitor
      WHERE e.day BETWEEN ? AND ? GROUP BY l.visitor ORDER BY last_day DESC`).all(since, until);
}

/// Daily and weekly active people per platform, who came back on 2+ days,
/// who was here before the window, and guests vs signed in.
export function peopleReport(db, { since, until, now = Date.now() }) {
  const out = {};
  const today = localDay(now), weekAgo = localDay(now - 6 * 86_400_000);
  for (const p of PLATFORMS) {
    const P = "COALESCE(platform,'web')=?";
    const dau = db.prepare(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE day=? AND ${P}`).get(today, p).n;
    const wau = db.prepare(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE day BETWEEN ? AND ? AND ${P}`).get(weekAgo, today, p).n;
    const avg = db.prepare(`SELECT AVG(n) n FROM (SELECT COUNT(DISTINCT visitor) n FROM site_events
        WHERE day BETWEEN ? AND ? AND ${P} GROUP BY day)`).get(since, until, p).n;
    const people = db.prepare(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE day BETWEEN ? AND ? AND ${P}`).get(since, until, p).n;
    const multi = db.prepare(`SELECT COUNT(*) n FROM (SELECT visitor FROM site_events WHERE day BETWEEN ? AND ? AND ${P}
        GROUP BY visitor HAVING COUNT(DISTINCT day) > 1)`).get(since, until, p).n;
    const before = db.prepare(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE day BETWEEN ? AND ? AND ${P}
        AND visitor IN (SELECT visitor FROM site_events WHERE day < ? AND ${P})`).get(since, until, p, since, p).n;
    const signed = db.prepare(`SELECT COUNT(DISTINCT visitor) n FROM site_events WHERE day BETWEEN ? AND ? AND ${P} AND signed_in=1`).get(since, until, p).n;
    const accounts = db.prepare(`SELECT COUNT(DISTINCT user_hash) n FROM site_events WHERE day BETWEEN ? AND ? AND ${P} AND user_hash IS NOT NULL`).get(since, until, p).n;
    out[p] = { dau_today: dau, dau_average: avg == null ? 0 : Math.round(avg * 10) / 10, wau, people,
      came_back_on_2plus_days: multi, returning_from_before: before, signed_in_people: signed, guests: people - signed, accounts };
  }
  return out;
}
