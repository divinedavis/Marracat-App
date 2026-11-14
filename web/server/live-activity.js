import express from "express";
import { createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { brandRecord } from "./catalog.js";
import { apnsSender } from "./restock.js";
import { mobileSessionUser } from "./mobile.js";
import { isOwnerEmail } from "./owner-metrics.js";
import { localNow, stepForTrackerStatus, orderKey } from "./relay.js";
import { itemPhrase, brandNameFor } from "./order-tracking.js";

// Deliveries arriving today, live in the Dynamic Island and on the Lock
// Screen (owner, 2026-10-13: "lets use dynamic island when a order is
// delivering that day and if there are multiple orders users should be able
// to swipe left and right through them").
//
// ONE Live Activity per phone holds every order arriving today; the app's
// ‹ › buttons (LiveActivityIntent) flip through them on the phone. Apple has
// no swipe gesture inside a Live Activity: only Button and Toggle with an
// App Intent are interactive, and a horizontal swipe on the island is the
// system's own (it shrinks or swaps activities).
//
// Server-driven, per Apple's "Starting and updating Live Activities with
// ActivityKit push notifications": the app sends its push-to-start token
// (iOS 17.2+) and, for each running activity, its update token. Both are
// keyed by the same per-install device key as restock alerts
// (X-Marracat-Device, stored hashed). Tokens are stored because pushes need
// them; they're never logged or sent back.
//
// Budget: start/end and real step changes go at priority 10 (counted by
// Apple), anything else at 5; on top of that, no more than one update a
// minute and MAX_PER_HOUR an hour per phone, or the update waits for the next
// sync.

const hash = (value) => createHash("sha256").update(value).digest("hex");
const deviceKey = /^[a-f0-9]{64}$/;
// ActivityKit tokens are longer than notification tokens (~80–100 bytes).
const pushToken = /^[a-f0-9]{64,400}$/;
const activityID = /^[A-Za-z0-9-]{8,80}$/;

export const ATTRIBUTES_TYPE = "DeliveryActivityAttributes";
export const SYNC_EVERY_MS = 2 * 60_000;
export const MIN_GAP_MS = 60_000;
export const MAX_PER_HOUR = 12;
export const MAX_ORDERS = 6;
// A start push can take a moment to reach the phone; a launch inside this
// window may not see the activity yet.
export const LAUNCH_GRACE_MS = 3 * 60_000;
// A Live Activity runs at most 8 hours (Apple); past that ours is gone.
const ACTIVITY_LIFETIME_MS = 8 * 60 * 60_000;
// Ended a little before Apple would, so we pick how long it lingers: an
// ended card stays on the Lock Screen at most 4 hours (Apple).
const END_BEFORE_LIFETIME_MS = 10 * 60_000;
const LINGER_MAX_S = 4 * 60 * 60;
// Delivered orders stay on the card until 11:59 pm that day (owner,
// 2026-10-17), or until the shopper dismisses them one by one.
const END_OF_DAY = { hour: 23, minute: 59 };
const orderID = /^[A-Za-z0-9_-]{1,40}$/;
// Not before 7 am or after 9 pm on the phone's clock, for an order merely due today.
const START_HOURS = [7, 21];

export const STATUS_RANK = { nearby: 0, out_for_delivery: 1, problem: 2, arriving: 3, delivered: 4 };

export function installLiveActivitySchema(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS live_activities (
    device TEXT PRIMARY KEY,
    start_token TEXT, start_env TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    activity_id TEXT, update_token TEXT, update_env TEXT,
    state TEXT, started INTEGER, dismissed_day TEXT,
    pushes TEXT, demo INTEGER,
    updated INTEGER NOT NULL)`);
  // Whether iOS lets this app show Live Activities (Settings › Marracat),
  // as the app last reported; null until it does (live-cover.js).
  const cols = db.prepare("PRAGMA table_info(live_activities)").all().map((c) => c.name);
  if (!cols.includes("authorized")) db.exec("ALTER TABLE live_activities ADD COLUMN authorized INTEGER");
  if (!cols.includes("hidden")) db.exec("ALTER TABLE live_activities ADD COLUMN hidden TEXT");
}

// ---- what's arriving today ----------------------------------------------

const clip = (s, n) => (typeof s === "string" && s.trim() ? s.trim().replace(/\s+/g, " ").slice(0, n) : null);

/// Carrier status → the island's words. null = not today's business.
export function liveStatus(step, estDay, today) {
  if (step === "delivered") return "delivered";
  if (step === "out_for_delivery") return "out_for_delivery";
  if (step === "problem") return estDay === today ? "problem" : null;
  if (estDay === today) return "arriving";
  return null;
}

/// Every order for this phone that arrives today, or arrived today: from the
/// order pages it follows (tracked_orders) and from the order email of the
/// account signed in on it (relay_events). One entry per package.
export function arrivingToday(db, device, { now = Date.now(), lookup = brandRecord } = {}) {
  const has = (t) => db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t);
  const tz = (has("restock_devices") && db.prepare("SELECT tz FROM restock_devices WHERE hash=?").get(device)?.tz) || "America/New_York";
  const today = localNow(now, tz).day;
  const dayOfMs = (ms) => (ms ? localNow(ms, tz).day : null);
  const out = [];
  const seen = new Set();
  const push = (o, packageKey) => {
    if (packageKey && seen.has(packageKey)) return;
    if (packageKey) seen.add(packageKey);
    out.push(o);
  };
  if (has("tracked_orders")) {
    const cols = new Set(db.prepare("SELECT name FROM pragma_table_info('tracked_orders')").all().map((c) => c.name));
    const est = cols.has("est_delivery") ? "est_delivery" : "NULL AS est_delivery";
    for (const r of db.prepare(`SELECT id, brand_id, order_gid, state, carrier, tracking_number, tracking_status, item_title, item_count, ${est}, done, updated
        FROM tracked_orders WHERE device=? AND (done IS NULL OR done > ?)`).all(device, now - 36 * 3600_000)) {
      const step = r.state === "delivered" ? "delivered" : stepForTrackerStatus(r.tracking_status) || r.state;
      if (step === "delivered" && dayOfMs(r.done || r.updated) !== today) continue;
      const status = liveStatus(step, r.est_delivery, today);
      if (!status) continue;
      const number = r.order_gid ? r.order_gid.split("/").pop() : null;
      push({
        id: `t${r.id}`, brand: clip(brandNameFor(r.brand_id, lookup), 40) || "Your order",
        item: clip(itemPhrase(r.item_title, r.item_count), 60), status, carrier: clip(r.carrier, 20), eta: null,
        link: `marracat://order?brand=${encodeURIComponent(r.brand_id)}${number ? `&order=${number}` : ""}`,
      }, r.tracking_number ? `n:${r.tracking_number}` : null);
    }
  }
  if (has("relay_events")) {
    const users = new Set();
    if (has("restock_links")) for (const l of db.prepare("SELECT user_id FROM restock_links WHERE device=?").all(device)) users.add(l.user_id);
    if (has("relay_addresses")) for (const a of db.prepare("SELECT user_id FROM relay_addresses WHERE device=?").all(device)) users.add(a.user_id);
    for (const user of users) {
      for (const e of db.prepare(`SELECT id, brand_name, brand_domain, order_name, carrier, tracking_number, tracking_status, tracking_updated, est_delivery, item_title, item_count
          FROM relay_events WHERE user_id=? AND tracking_number IS NOT NULL AND received > ? ORDER BY received DESC`).all(user, now - 60 * 86400_000)) {
        const step = stepForTrackerStatus(e.tracking_status);
        if (step === "delivered" && dayOfMs(e.tracking_updated) !== today) continue;
        const status = liveStatus(step, e.est_delivery, today);
        if (!status) continue;
        const ident = e.order_name ? `o:${e.brand_domain}|${orderKey(e.order_name)}` : null;
        if (ident && seen.has(ident)) continue;
        if (ident) seen.add(ident);
        push({
          id: `r${e.id}`, brand: clip(e.brand_name, 40) || "Your order", item: clip(itemPhrase(e.item_title, e.item_count), 60),
          status, carrier: clip(e.carrier, 20), eta: null,
          link: `marracat://order?domain=${encodeURIComponent(e.brand_domain || "")}${e.order_name ? `&name=${encodeURIComponent(e.order_name)}` : ""}`,
        }, `n:${e.tracking_number}`);
      }
    }
  }
  return { today, hour: localNow(now, tz).hour, orders: sortOrders(out) };
}

export const sortOrders = (orders) => [...orders].sort((a, b) => (STATUS_RANK[a.status] ?? 9) - (STATUS_RANK[b.status] ?? 9));

/// What the activity shows next: today's orders, plus any it already showed
/// that have dropped out (a delivered one stays, marked Delivered, until all
/// are). The index points at the order that changed, so an update brings it
/// forward; with nothing changed it stays where it was.
export function nextState(previous, orders, hidden = new Set()) {
  orders = orders.filter((o) => !hidden.has(o.id));
  const byID = new Map(orders.map((o) => [o.id, o]));
  const kept = (previous?.orders || []).map((o) => byID.get(o.id) || (o.status === "delivered" && !hidden.has(o.id) ? o : null)).filter(Boolean);
  const added = orders.filter((o) => !kept.some((k) => k.id === o.id));
  const list = sortOrders([...kept, ...added]).slice(0, MAX_ORDERS);
  const before = new Map((previous?.orders || []).map((o) => [o.id, o.status]));
  const changed = list.findIndex((o) => before.get(o.id) !== o.status);
  const prevIndex = previous ? Math.min(previous.index || 0, Math.max(list.length - 1, 0)) : 0;
  return { orders: list, index: changed >= 0 ? changed : prevIndex };
}

export const sameOrders = (a, b) => JSON.stringify(a?.orders || []) === JSON.stringify(b?.orders || []);
export const allDelivered = (state) => !!state?.orders?.length && state.orders.every((o) => o.status === "delivered");
/// The alert for an update that changes an order's step: the card's own
/// notification (sound, Lock Screen, Dynamic Island), standing in for the
/// order's ordinary one (live-cover.js). Null for a quiet update.
export function stepAlert(previous, state) {
  const before = new Map((previous?.orders || []).map((o) => [o.id, o.status]));
  const changed = state.orders.find((o) => before.get(o.id) !== o.status && o.status !== "arriving");
  if (!changed) return null;
  const title = { out_for_delivery: "Out for delivery", nearby: "Nearby", delivered: "Delivered", problem: "Delivery problem" }[changed.status];
  return title ? { title, body: `${changed.brand}${changed.item ? ` · ${changed.item}` : ""}` } : null;
}

/// A status change worth Apple's priority-10 budget: something moved to out
/// for delivery, nearby, delivered or a problem.
export function urgent(previous, state) {
  const before = new Map((previous?.orders || []).map((o) => [o.id, o.status]));
  return state.orders.some((o) => before.get(o.id) !== o.status && o.status !== "arriving");
}

/// 11:59 pm today on the phone's clock, as epoch ms (to the minute).
export function endOfDayMs(ms, tz) {
  let parts;
  try { parts = new Intl.DateTimeFormat("en-US", { timeZone: tz || "America/New_York", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }).formatToParts(new Date(ms)); }
  catch { return endOfDayMs(ms, "America/New_York"); }
  const get = (t) => Number(parts.find((p) => p.type === t)?.value);
  const into = (get("hour") * 60 + get("minute")) * 60 + get("second");
  return ms + ((END_OF_DAY.hour * 60 + END_OF_DAY.minute) * 60 - into) * 1000;
}

// ---- payloads (Apple's documented aps keys) -----------------------------

export function startPayload(state, now, alert) {
  return { aps: { timestamp: Math.floor(now / 1000), event: "start", "content-state": state,
    "attributes-type": ATTRIBUTES_TYPE, attributes: { kind: "deliveries" },
    // iOS 18+: wake the app with a fresh update token for this activity.
    "input-push-token": 1,
    alert, "relevance-score": 100 } };
}
export function updatePayload(state, now, alert = null) {
  return { aps: { timestamp: Math.floor(now / 1000), event: "update", "content-state": state, ...(alert ? { alert } : {}) } };
}
export function endPayload(state, now, dismissAtSeconds) {
  return { aps: { timestamp: Math.floor(now / 1000), event: "end", "content-state": state, "dismissal-date": dismissAtSeconds } };
}

export function startAlert(state) {
  const open = state.orders.filter((o) => o.status !== "delivered");
  if (open.length === 1) {
    const o = open[0];
    return { title: o.status === "out_for_delivery" ? "Out for delivery" : "Arriving today", body: `${o.brand}${o.item ? ` · ${o.item}` : ""}` };
  }
  return { title: "Arriving today", body: `${open.length} orders are on their way to you today.` };
}

// ---- the sender ---------------------------------------------------------

export function liveActivities(db, { env = process.env, apns = apnsSender(env), lookup = brandRecord, now = Date.now, log = console.log,
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)) } = {}) {
  installLiveActivitySchema(db);
  const row = (device) => db.prepare("SELECT * FROM live_activities WHERE device=?").get(device);
  const ensure = (device) => db.prepare("INSERT OR IGNORE INTO live_activities(device, updated) VALUES(?,?)").run(device, now());
  const save = (device, fields) => {
    const keys = Object.keys(fields);
    db.prepare(`UPDATE live_activities SET ${keys.map((k) => `${k}=@${k}`).join(", ")}, updated=@updated_ WHERE device=@device_`)
      .run({ ...fields, updated_: now(), device_: device });
  };
  const clear = (device) => save(device, { activity_id: null, update_token: null, update_env: null, state: null, started: null, demo: null });
  const tzOf = (device) => (db.prepare("SELECT 1 FROM sqlite_master WHERE name='restock_devices'").get()
    ? db.prepare("SELECT tz FROM restock_devices WHERE hash=?").get(device)?.tz : null) || "America/New_York";
  /// Orders the shopper dismissed from today's card ("Dismiss" on a
  /// delivered one): {day, ids}; yesterday's list counts for nothing.
  const hiddenToday = (r, today) => {
    try { const h = JSON.parse(r?.hidden || "null"); return new Set(h?.day === today ? h.ids : []); } catch { return new Set(); }
  };
  const hide = (device, id) => {
    ensure(device);
    const today = localNow(now(), tzOf(device)).day;
    const ids = [...hiddenToday(row(device), today), id].slice(-20);
    save(device, { hidden: JSON.stringify({ day: today, ids: [...new Set(ids)] }) });
  };

  // Per-phone pacing: one push a minute, MAX_PER_HOUR an hour. Ends always go.
  const recent = (r) => { try { return (JSON.parse(r.pushes || "[]")).filter((t) => t > now() - 3600_000); } catch { return []; } };
  const allowed = (r) => { const p = recent(r); return p.length < MAX_PER_HOUR && !(p.length && now() - Math.max(...p) < MIN_GAP_MS); };
  const spend = (device, r) => save(device, { pushes: JSON.stringify([...recent(r), now()]) });

  async function send(device, kind, token, environment, payload, priority) {
    const result = await apns.send({ token, environment }, payload, { pushType: "liveactivity", priority });
    if (result.status === 200) {
      if (result.environment && result.environment !== environment)
        save(device, kind === "start" ? { start_env: result.environment } : { update_env: result.environment });
      return true;
    }
    // Never the token: only what APNs said.
    log(`Live Activity ${kind} push not delivered (${result.status} ${result.reason})`);
    if (result.status === 410 || (result.status === 400 && result.reason === "BadDeviceToken")) {
      if (kind === "start") save(device, { start_token: null });
      else clear(device);
    }
    return false;
  }

  /// Bring one phone's activity in line with what's arriving today.
  async function sync(device) {
    const r = row(device);
    if (!r || r.demo) return "skip";
    const previous = r.state ? JSON.parse(r.state) : null;
    if (previous && r.started && now() - r.started > ACTIVITY_LIFETIME_MS) { clear(device); return "expired"; }
    const tz = tzOf(device);
    const dayEnd = endOfDayMs(now(), tz);
    // The day is over, or Apple's 8 hours nearly are: end it ourselves,
    // lingering on the Lock Screen until 11:59 pm where Apple allows.
    // (The sync runs every 2 minutes, so "the day is over" is its last run before 11:59.)
    const dayOver = now() >= dayEnd - SYNC_EVERY_MS;
    if (previous && r.update_token && (dayOver || (r.started && now() - r.started > ACTIVITY_LIFETIME_MS - END_BEFORE_LIFETIME_MS))) {
      // At Apple's 8 hours with an order still on its way, the next sync
      // starts a fresh card, so this one leaves at once: lingering, it sat
      // beside its replacement (owner, 2026-10-25: "we shouldnt see two").
      const replaced = !dayOver && previous.orders.some((o) => o.status !== "delivered");
      const until = replaced ? Math.floor(now() / 1000)
        : Math.min(Math.floor(dayEnd / 1000), Math.floor(now() / 1000) + LINGER_MAX_S);
      await send(device, "end", r.update_token, r.update_env, endPayload(previous, now(), Math.max(until, Math.floor(now() / 1000))), 10);
      clear(device);
      return "ended";
    }
    if (!r.enabled) {
      if (previous && r.update_token) {
        await send(device, "end", r.update_token, r.update_env, endPayload(previous, now(), Math.floor(now() / 1000)), 10);
      }
      if (previous) clear(device);
      return "off";
    }
    const { today, hour, orders: all } = arrivingToday(db, device, { now: now(), lookup });
    const hidden = hiddenToday(r, today);
    const orders = all.filter((o) => !hidden.has(o.id));
    if (!previous) {
      const open = orders.filter((o) => o.status !== "delivered");
      if (!open.length || !r.start_token || r.dismissed_day === today) return "idle";
      // Merely "due today" waits for the morning; out for delivery doesn't.
      if (!open.some((o) => o.status === "out_for_delivery") && (hour < START_HOURS[0] || hour >= START_HOURS[1])) return "idle";
      if (!allowed(r)) return "paced";
      const state = nextState(null, open);
      spend(device, r);
      // Saved first: the phone may send the new activity's token back before
      // APNs has even answered.
      save(device, { state: JSON.stringify(state), started: now(), activity_id: null, update_token: null });
      if (!await send(device, "start", r.start_token, r.start_env, startPayload(state, now(), startAlert(state)), 10)) { clear(device); return "failed"; }
      return "started";
    }
    const state = nextState(previous, orders, hidden);
    if (!state.orders.length) {
      // Nothing to show any more (orders cancelled or gone): end it now.
      if (r.update_token) await send(device, "end", r.update_token, r.update_env, endPayload(previous, now(), Math.floor(now() / 1000)), 10);
      clear(device);
      return "ended";
    }
    if (sameOrders(previous, state)) return "same";
    // The app hasn't sent the activity's update token yet; try again next sync.
    if (!r.update_token) return "waiting";
    if (!allowed(r)) return "paced";
    spend(device, r);
    if (!await send(device, "update", r.update_token, r.update_env, updatePayload(state, now(), stepAlert(previous, state)), urgent(previous, state) ? 10 : 5)) return "failed";
    save(device, { state: JSON.stringify(state) });
    return "updated";
  }

  async function syncAll() {
    const counts = {};
    for (const { device } of db.prepare("SELECT device FROM live_activities WHERE (start_token IS NOT NULL OR state IS NOT NULL) AND demo IS NULL").all()) {
      let result;
      try { result = await sync(device); } catch (e) { result = "error"; log(`Live Activity sync failed: ${e.name}`); }
      counts[result] = (counts[result] || 0) + 1;
    }
    return counts;
  }

  // ---- the owner's demo -------------------------------------------------

  // Three made-up orders that move out for delivery → nearby → delivered over
  // about two minutes, on the owner's own phone (owner, 2026-10-13: "give me
  // a test"). Nothing about them is stored as an order.
  const DEMO = [
    { id: "demo-ripl", brand: "Ripl Efek", item: "Laundry Detergent", carrier: "UPS" },
    { id: "demo-koba", brand: "KOBA", item: "Keep It Together Headband", carrier: "USPS" },
    { id: "demo-telfar", brand: "Telfar", item: "Medium Shopping Bag", carrier: "FedEx" },
  ];
  const demoSteps = () => {
    const o = (i, status, eta) => ({ ...DEMO[i], status, eta, link: "marracat://orders" });
    return [
      { orders: [o(0, "out_for_delivery", "By 2:30 PM"), o(1, "out_for_delivery", "By 5 PM"), o(2, "out_for_delivery", "By 8 PM")], index: 0 },
      { orders: [o(0, "nearby", "3 stops away"), o(1, "out_for_delivery", "By 5 PM"), o(2, "out_for_delivery", "By 8 PM")], index: 0 },
      { orders: [o(1, "nearby", "2 stops away"), o(2, "out_for_delivery", "By 8 PM"), o(0, "delivered", "Left at front door")], index: 0 },
      { orders: [o(2, "nearby", "Next stop"), o(0, "delivered", "Left at front door"), o(1, "delivered", "Handed to resident")], index: 0 },
      { orders: [o(0, "delivered", "Left at front door"), o(1, "delivered", "Handed to resident"), o(2, "delivered", "Left in mailroom")], index: 0 },
    ];
  };
  const DEMO_GAP_MS = 30_000;

  /// Runs the demo; resolves when it's over. The caller doesn't wait.
  async function demo(device) {
    const r = row(device);
    if (!r?.start_token) return { ok: false, reason: "no_start_token" };
    if (r.demo) return { ok: false, reason: "running" };
    save(device, { demo: 1, state: null, update_token: null, activity_id: null, started: null });
    const steps = demoSteps();
    try {
      if (!await send(device, "start", r.start_token, r.start_env,
        startPayload(steps[0], now(), { title: "Live Activity test", body: "3 orders arriving today: Ripl Efek, KOBA, Telfar" }), 10)) return { ok: false, reason: "start_failed" };
      for (let i = 1; i < steps.length; i++) {
        await sleep(DEMO_GAP_MS);
        // The phone sends the activity's update token once it's running.
        let token = row(device)?.update_token;
        for (let wait = 0; !token && wait < 6; wait++) { await sleep(5_000); token = row(device)?.update_token; }
        if (!token) { log("Live Activity demo: no update token from the phone"); return { ok: false, reason: "no_update_token" }; }
        const env = row(device).update_env;
        const last = i === steps.length - 1;
        const payload = last ? endPayload(steps[i], now(), Math.floor(now() / 1000) + 120) : updatePayload(steps[i], now());
        if (!await send(device, last ? "end" : "update", token, env, payload, 10)) return { ok: false, reason: "update_failed" };
      }
      return { ok: true };
    } finally {
      save(device, { demo: null, state: null, update_token: null, activity_id: null, started: null });
    }
  }

  return { sync, syncAll, demo, row, ensure, save, clear, hide, demoSteps };
}

// ---- HTTP: the app's calls ------------------------------------------------

export function liveActivityRoutes(app, db, { env = process.env, live = liveActivities(db, { env }), schedule = env.NODE_ENV === "production" } = {}) {
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "4kb" }));
  router.use((req, res, next) => {
    const key = req.get("X-Marracat-Device");
    if (!key || !deviceKey.test(key)) return res.status(401).json({ error: "Missing device key" });
    req.device = hash(key);
    live.ensure(req.device);
    next();
  });
  const environment = (e) => (["production", "sandbox"].includes(e) ? e : null);

  // Whether this phone gets Live Activities, and whether the signed-in
  // account may run the demo (the app shows the row only then).
  router.get("/status", (req, res) => {
    const user = mobileSessionUser(db, req);
    res.json({ enabled: !!live.row(req.device).enabled, owner: !!user && isOwnerEmail(user.email, env) });
  });
  router.put("/start-token", (req, res) => {
    const { token, environment: e } = req.body || {};
    if (typeof token !== "string" || !pushToken.test(token) || !environment(e)) return res.status(400).json({ error: "Invalid token" });
    live.save(req.device, { start_token: token, start_env: e });
    res.sendStatus(204);
  });
  router.put("/settings", async (req, res) => {
    const { enabled } = req.body || {};
    if (typeof enabled !== "boolean") return res.status(400).json({ error: "Invalid setting" });
    live.save(req.device, { enabled: enabled ? 1 : 0 });
    // Off ends a running one now.
    if (!enabled) await live.sync(req.device).catch(() => {});
    res.sendStatus(204);
  });
  // A running activity's update token (it can change while it runs).
  router.put("/activity", (req, res) => {
    const { activityID: id, token, environment: e } = req.body || {};
    if (typeof id !== "string" || !activityID.test(id) || typeof token !== "string" || !pushToken.test(token) || !environment(e))
      return res.status(400).json({ error: "Invalid activity" });
    const r = live.row(req.device);
    // Only while the server is running one for this phone (or the demo is).
    if (!r.state && !r.demo) return res.status(409).json({ error: "No activity" });
    live.save(req.device, { activity_id: id, update_token: token, update_env: e });
    res.sendStatus(204);
  });
  // At launch the app lists the activities really on screen. One the server
  // still counts as running but the phone doesn't have ended without a word:
  // an app update takes a phone's Live Activities down, and so does a swipe
  // while the app isn't running to report it (owner, 2026-10-17: a card for
  // an order arriving that day was gone, and the server, still "running" it,
  // never started another). Forget it so the next sync starts a fresh one —
  // unless it started moments ago and may not have reached the phone yet.
  router.put("/running", (req, res) => {
    const ids = req.body?.activityIDs;
    if (!Array.isArray(ids) || ids.length > 10 || !ids.every((id) => typeof id === "string" && activityID.test(id)))
      return res.status(400).json({ error: "Invalid activities" });
    // Optional: whether iOS lets the app show Live Activities at all.
    if (typeof req.body?.authorized === "boolean") { live.ensure(req.device); live.save(req.device, { authorized: req.body.authorized ? 1 : 0 }); }
    const r = live.row(req.device);
    // Unknown to us but on screen: a card whose update token hasn't arrived
    // yet (iOS hands it over only while the app runs). Clearing that started
    // a second card beside it (owner, 2026-10-25), so any card on screen
    // keeps ours.
    if (r?.state && !r.demo && r.started && Date.now() - r.started > LAUNCH_GRACE_MS && !ids.length) {
      live.clear(req.device);
      console.log("Live Activities: one the phone no longer had was cleared");
    }
    res.sendStatus(204);
  });
  // "Dismiss" on a delivered order in the card: the app has already taken it
  // off this phone's card; it stays off for the rest of the day.
  router.put("/hide", async (req, res) => {
    const id = req.body?.orderID;
    if (typeof id !== "string" || !orderID.test(id)) return res.status(400).json({ error: "Invalid order" });
    live.hide(req.device, id);
    await live.sync(req.device).catch(() => {});
    res.sendStatus(204);
  });
  // The shopper swiped it away: no new one today.
  router.delete("/activity", (req, res) => {
    const { activityID: id } = req.body || {};
    const r = live.row(req.device);
    if (r.state && !r.demo && (!r.activity_id || r.activity_id === id)) {
      const tz = db.prepare("SELECT 1 FROM sqlite_master WHERE name='restock_devices'").get()
        ? db.prepare("SELECT tz FROM restock_devices WHERE hash=?").get(req.device)?.tz : null;
      live.save(req.device, { dismissed_day: localNow(Date.now(), tz || "America/New_York").day });
      live.clear(req.device);
    }
    res.sendStatus(204);
  });
  // Forget this phone: tokens, setting and any running activity's record.
  router.delete("/", async (req, res) => {
    live.save(req.device, { enabled: 0 });
    await live.sync(req.device).catch(() => {});
    db.prepare("DELETE FROM live_activities WHERE device=?").run(req.device);
    res.sendStatus(204);
  });
  // The owner's test: signed in as an owner account, from this phone.
  router.post("/demo", (req, res) => {
    const user = mobileSessionUser(db, req);
    if (!user) return res.status(401).json({ error: "Sign in first" });
    if (!isOwnerEmail(user.email, env)) return res.status(403).json({ error: "Owner only" });
    const r = live.row(req.device);
    if (!r.start_token) return res.status(409).json({ error: "This iPhone hasn't registered for Live Activities yet (iOS 17.2 or later, Live Activities on)." });
    if (r.demo) return res.status(409).json({ error: "A test is already running" });
    live.demo(req.device).then((result) => console.log(`Live Activity demo: ${result.ok ? "done" : result.reason}`))
      .catch((e) => console.error("Live Activity demo failed:", e.name));
    res.status(202).json({ started: true });
  });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/live-activity", router);

  if (schedule) {
    let running = false;
    const run = async () => {
      if (running) return;
      running = true;
      try {
        const c = await live.syncAll();
        const moved = ["started", "updated", "ended", "failed"].filter((k) => c[k]).map((k) => `${c[k]} ${k}`);
        if (moved.length) console.log(`Live Activities: ${moved.join(", ")}`);
      } catch (e) { console.error("Live Activity sync failed:", e.name); } finally { running = false; }
    };
    setTimeout(run, 75_000).unref();
    setInterval(run, SYNC_EVERY_MS).unref();
  }
  return live;
}
