// Boosts: anyone can pay to promote a product or a brand on Marracat's Home
// (owner, 2026-10-04). Fixed tiers, paid through Stripe Checkout on the website
// (the app links out to it), labeled "Sponsored" wherever they show.
//
//   $100  a page in the Home carousel (3 of its premier pages are reserved), 7 days
//    $50  "Boosted picks" row + a lift in its aisle and search, 7 days
//    $20  "Boosted picks" row, 3 days
//     $5  a lift in its aisle and search + a badge, 24 hours
//
// Boosts for the same product or brand add up while they run, so five fans'
// $20 boosts put a brand in the carousel. Only the catalog's own photos and
// titles are shown (no custom creative), so nothing needs review. A boosted
// product that sells out shows its brand instead. Boosters see how many people
// saw and tapped what they boosted.
import express from "express";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { brandRecord, productRecord } from "./catalog.js";
import { localDay } from "./visits.js";
import { isOwnerEmail } from "./owner-metrics.js";
import { installBudgetSchema, firstDelivery, handleBudgetEvent, allocateBudgets } from "./boost-budgets.js";

export const TIERS = {
  5: { days: 1, label: "Spark", places: ["lift"] },
  20: { days: 3, label: "Boost", places: ["picks"] },
  50: { days: 7, label: "Big boost", places: ["picks", "lift"] },
  100: { days: 7, label: "Spotlight", places: ["premier", "picks", "lift"] },
};
const PREMIER_SLOTS = 3;
const DAY_MS = 86400 * 1000;
const sha = (v) => createHash("sha256").update(v).digest("hex");

export function installBoostSchema(db) {
  // Older tables: add the live flag (test-mode boosts never show publicly).
  try { db.exec("ALTER TABLE boosts ADD COLUMN live INTEGER NOT NULL DEFAULT 1"); } catch { /* new table or already there */ }
  db.exec(`
    CREATE TABLE IF NOT EXISTS boosts (
      id TEXT PRIMARY KEY, target TEXT NOT NULL, tier INTEGER NOT NULL, amount_cents INTEGER NOT NULL,
      user_id TEXT, status TEXT NOT NULL DEFAULT 'pending', session TEXT UNIQUE,
      created INTEGER NOT NULL, starts INTEGER, ends INTEGER, live INTEGER NOT NULL DEFAULT 1);
    CREATE INDEX IF NOT EXISTS boosts_target ON boosts(target, status);
    CREATE INDEX IF NOT EXISTS boosts_user ON boosts(user_id);
    CREATE TABLE IF NOT EXISTS boost_events (
      target TEXT NOT NULL, day TEXT NOT NULL, kind TEXT NOT NULL, visitor TEXT NOT NULL,
      PRIMARY KEY (target, day, kind, visitor));`);
}

/// "product:<id>" or "brand:<id>", or null when it isn't on Marracat.
export function targetKey(type, id, lookup = { productRecord, brandRecord }) {
  if (type === "product" && lookup.productRecord(String(id))) return `product:${id}`;
  if (type === "brand" && lookup.brandRecord(String(id))) return `brand:${id}`;
  return null;
}

/// The tier a running total reaches: the highest tier it covers.
export function tierFor(cents) {
  return [100, 50, 20, 5].find((t) => cents >= t * 100) || 0;
}

/// What's boosted right now: running totals per target, each at the tier its
/// total reaches. A sold-out or removed product shows its brand instead.
export function activeBoosts(db, now = Date.now(), lookup = { productRecord, brandRecord }, rotateSeed = Math.floor(now / 3600e3), { includeTest = false } = {}) {
  // Boosts paid in Stripe's test mode never show to the public: a free test
  // card must not buy a real Sponsored spot (found 2026-10-04).
  const rows = db.prepare(`SELECT target, SUM(amount_cents) AS cents, MIN(starts) AS since FROM boosts
    WHERE status='paid' AND starts<=? AND ends>? ${includeTest ? "" : "AND live=1"} GROUP BY target`).all(now, now);
  const byTarget = new Map();
  for (const r of rows) {
    let target = r.target;
    if (target.startsWith("product:")) {
      const p = lookup.productRecord(target.slice(8));
      if (!p || !p.available) target = p ? `brand:${p.brand}` : null;
    }
    if (!target || (target.startsWith("brand:") && !lookup.brandRecord(target.slice(6)))) continue;
    const e = byTarget.get(target) || { target, cents: 0, since: r.since };
    e.cents += r.cents;
    e.since = Math.min(e.since, r.since);
    byTarget.set(target, e);
  }
  const all = [...byTarget.values()].map((e) => ({ ...e, tier: tierFor(e.cents) })).filter((e) => e.tier);
  const at = (place) => all.filter((e) => TIERS[e.tier].places.includes(place));
  // More Spotlights than slots: biggest first, rotating every hour among equals.
  const premier = at("premier").sort((a, b) => b.cents - a.cents || ((sha(a.target + rotateSeed) < sha(b.target + rotateSeed)) ? -1 : 1));
  return {
    premier: premier.slice(0, PREMIER_SLOTS).map((e) => e.target),
    picks: at("picks").sort((a, b) => b.cents - a.cents || a.since - b.since).map((e) => e.target),
    lift: at("lift").map((e) => e.target),
    label: "Sponsored",
  };
}

// ---- Stripe (no SDK: two calls and a signature check) ----------------------

/// `idempotencyKey`: Stripe answers a repeat of the same key with the first
/// answer instead of doing the thing twice. An error Stripe itself gave
/// carries `answered`; one without it (a timeout, no network) leaves unknown
/// whether the request went through.
export async function stripe(env, method, path, form, fetcher = fetch, { idempotencyKey = null } = {}) {
  const res = await fetcher(`https://api.stripe.com/v1/${path}`, {
    method,
    headers: { Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`, "Content-Type": "application/x-www-form-urlencoded",
      ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}) },
    body: form ? new URLSearchParams(form).toString() : undefined,
    signal: AbortSignal.timeout(20_000),
  });
  const body = await res.json();
  if (!res.ok) throw Object.assign(Error(body?.error?.message || `Stripe ${res.status}`), { answered: true });
  return body;
}

/// Stripe-Signature check (t=…,v1=…), five-minute tolerance.
export function verifyStripeSignature(raw, header, secret, now = Date.now()) {
  if (!secret || !header) return false;
  const parts = Object.fromEntries(String(header).split(",").map((p) => p.split("=")).filter((p) => p.length === 2));
  const t = Number(parts.t);
  if (!t || Math.abs(now / 1000 - t) > 300) return false;
  const expected = createHmac("sha256", secret).update(`${t}.${raw}`).digest("hex");
  const sigs = String(header).split(",").filter((p) => p.startsWith("v1=")).map((p) => p.slice(3));
  return sigs.some((s) => s.length === expected.length && timingSafeEqual(Buffer.from(s), Buffer.from(expected)));
}

function markPaid(db, sessionID, now) {
  const b = db.prepare("SELECT * FROM boosts WHERE session=?").get(sessionID);
  if (!b || b.status === "paid") return b;
  const days = TIERS[b.tier].days;
  db.prepare("UPDATE boosts SET status='paid', starts=?, ends=? WHERE id=?").run(now, now + days * DAY_MS, b.id);
  return db.prepare("SELECT * FROM boosts WHERE id=?").get(b.id);
}

function describe(target, lookup = { productRecord, brandRecord }) {
  if (target.startsWith("product:")) {
    const p = lookup.productRecord(target.slice(8));
    return { type: "product", id: target.slice(8), name: p?.title || "A product", brand: p?.brand, image: p?.images?.[0] };
  }
  const b = lookup.brandRecord(target.slice(6));
  return { type: "brand", id: target.slice(6), name: b?.name || "A brand", image: b?.image };
}

export function boostRoutes(app, db, { env = process.env, viewer = async () => null, fetcher = fetch, now = Date.now } = {}) {
  installBoostSchema(db);
  installBudgetSchema(db);
  const json = express.json({ limit: "4kb" });
  const limit = (n) => rateLimit({ windowMs: 60_000, limit: n, standardHeaders: "draft-8", legacyHeaders: false });
  const site = env.PUBLIC_URL || "https://marracat.com";

  app.get("/api/boosts/tiers", (_req, res) => res.json(Object.entries(TIERS).map(([d, t]) => ({ dollars: Number(d), ...t }))));

  // What's boosted now, for Home, aisles and search (cached briefly by clients).
  const testMode = () => !String(env.STRIPE_SECRET_KEY || "").startsWith("sk_live_");
  const isOwner = (user) => !!user && isOwnerEmail(user.email);

  // Whether this visitor gets the Boost button: everyone once Stripe is live;
  // only the owner while it's in test mode.
  app.get("/api/boosts/status", async (req, res) => {
    const user = await viewer(req).catch(() => null);
    res.set("Cache-Control", "private, no-store");
    res.json({ enabled: !!env.STRIPE_SECRET_KEY && (!testMode() || isOwner(user)), test: testMode() });
  });

  app.get("/api/boosts/active", async (req, res) => {
    // The owner previews test-mode boosts; everyone else sees live ones only.
    const preview = testMode() && isOwner(await viewer(req).catch(() => null));
    res.set("Cache-Control", preview ? "private, no-store" : "public, max-age=60");
    res.json(activeBoosts(db, now(), undefined, undefined, { includeTest: preview }));
  });

  // Start a boost: a Stripe Checkout page for the chosen tier.
  app.post("/api/boosts/checkout", limit(10), json, async (req, res) => {
    if (!env.STRIPE_SECRET_KEY) return res.status(503).json({ error: "Boosts aren't available yet." });
    const user = await viewer(req).catch(() => null);
    if (testMode() && !isOwner(user)) return res.status(503).json({ error: "Boosts aren't available yet." });
    const tier = Number(req.body?.tier);
    if (!TIERS[tier]) return res.status(400).json({ error: "Pick $5, $20, $50 or $100." });
    const target = targetKey(req.body?.type, req.body?.id);
    if (!target) return res.status(404).json({ error: "That isn't on Marracat." });
    const what = describe(target);
    const id = randomBytes(9).toString("hex");
    try {
      const session = await stripe(env, "POST", "checkout/sessions", {
        mode: "payment",
        "line_items[0][quantity]": "1",
        "line_items[0][price_data][currency]": "usd",
        "line_items[0][price_data][unit_amount]": String(tier * 100),
        "line_items[0][price_data][product_data][name]": `${TIERS[tier].label} for ${what.name} on Marracat`.slice(0, 250),
        "line_items[0][price_data][product_data][description]": `Sponsored placement for ${TIERS[tier].days === 1 ? "24 hours" : TIERS[tier].days + " days"}, labeled "Sponsored".`,
        success_url: `${site}/#/boosts?paid={CHECKOUT_SESSION_ID}`,
        cancel_url: `${site}/#/boosts?canceled=1`,
        client_reference_id: id,
        "metadata[boost]": id,
        "metadata[target]": target,
        "metadata[tier]": String(tier),
        ...(user?.email ? { customer_email: user.email } : {}),
      }, fetcher);
      db.prepare("INSERT INTO boosts(id,target,tier,amount_cents,user_id,session,created,live) VALUES(?,?,?,?,?,?,?,?)")
        .run(id, target, tier, tier * 100, user?.id || null, session.id, now(), session.livemode ? 1 : 0);
      res.status(201).json({ url: session.url });
    } catch (e) {
      res.status(502).json({ error: "Checkout couldn't start. Try again." });
    }
  });

  // Back from Checkout: confirm with Stripe directly (works even before the
  // webhook arrives), then show the boost.
  app.get("/api/boosts/session/:id", limit(30), async (req, res) => {
    const sid = String(req.params.id);
    if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(sid)) return res.sendStatus(400);
    let b = db.prepare("SELECT * FROM boosts WHERE session=?").get(sid);
    if (!b) return res.sendStatus(404);
    if (b.status !== "paid" && env.STRIPE_SECRET_KEY) {
      try {
        const s = await stripe(env, "GET", `checkout/sessions/${sid}`, null, fetcher);
        if (s.payment_status === "paid") b = markPaid(db, sid, now());
      } catch { /* show it as pending */ }
    }
    res.json({ status: b.status, ...describe(b.target), tier: b.tier, starts: b.starts, ends: b.ends });
  });

  // Stripe's own confirmation.
  app.post("/api/stripe/webhook", express.raw({ type: "application/json", limit: "1mb" }), (req, res) => {
    const raw = req.body.toString("utf8");
    if (!verifyStripeSignature(raw, req.get("Stripe-Signature"), env.STRIPE_WEBHOOK_SECRET, now())) return res.sendStatus(400);
    let event;
    try { event = JSON.parse(raw); } catch { return res.sendStatus(400); }
    // Each event once (Stripe retries and replays must not credit a budget
    // twice), recorded in the same transaction as its effects: if handling
    // throws, nothing is recorded and Stripe's retry is processed.
    try {
      db.transaction(() => {
        if (!firstDelivery(db, event, now())) return;
        const s = event?.data?.object;
        if (event.type === "checkout.session.completed" && s?.payment_status === "paid" && s?.mode !== "subscription") markPaid(db, s.id, now());
        if (event.type === "checkout.session.async_payment_succeeded") markPaid(db, s.id, now());
        // Monthly budgets (boost-budgets.js): subscriptions, invoices, cancellations.
        if (handleBudgetEvent(db, event, now())) allocateBudgets(db, now());
      })();
    } catch {
      return res.sendStatus(500);
    }
    res.sendStatus(200);
  });

  // Seen / tapped, once per visitor per target per day.
  app.post("/api/boosts/events", limit(60), json, (req, res) => {
    const visitor = String(req.get("X-Marracat-Device") || req.body?.id || "");
    if (!/^[A-Za-z0-9_-]{16,128}$/.test(visitor)) return res.sendStatus(400);
    const events = Array.isArray(req.body?.events) ? req.body.events.slice(0, 50) : [];
    // Counted once per IP, not per client-chosen id (audit 2026-10-07): a
    // made-up id per request would otherwise inflate a booster's numbers.
    const day = localDay(now()), v = sha("ip:" + (req.ip || "unknown"));
    const live = new Set(db.prepare("SELECT DISTINCT target FROM boosts WHERE status='paid' AND ends>?").all(now() - DAY_MS).map((r) => r.target));
    const add = db.prepare("INSERT OR IGNORE INTO boost_events(target,day,kind,visitor) VALUES(?,?,?,?)");
    for (const e of events) {
      const target = String(e?.target || ""), kind = e?.kind === "tap" ? "tap" : "view";
      if (live.has(target)) add.run(target, day, kind, v);
    }
    res.sendStatus(204);
  });

  // The signed-in booster's boosts, with how many saw and tapped them.
  app.get("/api/boosts/mine", async (req, res) => {
    const user = await viewer(req).catch(() => null);
    if (!user) return res.status(401).json({ error: "Sign in to see your boosts." });
    const count = db.prepare("SELECT kind, COUNT(*) AS n FROM boost_events WHERE target=? AND day>=? AND day<=? GROUP BY kind");
    const rows = db.prepare("SELECT * FROM boosts WHERE user_id=? AND status='paid' ORDER BY starts DESC LIMIT 100").all(user.id);
    res.json(rows.map((b) => {
      const stats = Object.fromEntries(count.all(b.target, localDay(b.starts), localDay(b.ends)).map((r) => [r.kind, r.n]));
      return { id: b.id, ...describe(b.target), tier: b.tier, starts: b.starts, ends: b.ends, running: b.ends > now(),
        views: stats.view || 0, taps: stats.tap || 0 };
    }));
  });
}
