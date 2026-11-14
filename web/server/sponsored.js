// Sponsored products: verified brands promote their own products, paying per
// tap (owner, 2026-10-05: the Amazon/Etsy model, "they need to verify its
// them first then they can do it from the mobile app or website").
//
//  - Only an account in brand_admins (verified by a one-time link to an
//    address at the brand's own domain, brand-claims.js) can run a campaign
//    for that brand, and only for that brand's own products.
//  - One campaign per brand: which products, a daily budget, and the most it
//    will pay per tap. A card is saved once through Stripe Checkout (setup
//    mode); taps are charged once $25 is owed, or weekly.
//  - Placements: the top two results of a search, a "Sponsored" row on
//    related product pages, and one spot in an aisle. Every one is labeled.
//    The highest bid wins, weighted by how well the product fits; a tap costs
//    a cent over the next bid (at least 20 cents, never above the brand's
//    own cap).
//  - Fair taps: one charged tap per phone (or browser) per product per day,
//    none from the brand's own people, none past 30 taps an hour from one
//    phone, none once the day's budget is spent.
//  - While Stripe is in test mode, sponsored spots show only to the owner.
//  - A new campaign, or one whose products change, waits for the owner's
//    approval before it shows (audit 2026-10-07; the comment above always
//    said so, the code started campaigns at once).
//  - A tap is charged only with a signed, single-use impression id from
//    /serve, and at most TAPS_PER_IP_DAY charged taps per IP a day. Taps
//    without one (App Store builds before 1.4) are recorded, never charged
//    (audit 2026-10-07: the device header alone was client-chosen).
import express from "express";
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { productRecord, brandRecord, allProducts } from "./catalog.js";
import { viewerOf } from "./social.js";
import { stripe } from "./boosts.js";
import { isOwnerEmail } from "./owner-metrics.js";

export const MIN_BUDGET_CENTS = 500;
export const MAX_BUDGET_CENTS = 50_000;
export const MIN_CPC_CENTS = 20;
export const MAX_CPC_CENTS = 500;
export const BILL_AT_CENTS = 2_500;
const WEEK_MS = 7 * 86400_000;
const MAX_PRODUCTS = 50;
const TAPS_PER_HOUR = 30;
const TAPS_PER_IP_DAY = 10;
const IMPRESSION_TTL_MS = 30 * 60_000;
const sha = (v) => createHash("sha256").update(v).digest("hex");

export function installSponsoredSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS ad_campaigns (
      brand_id TEXT PRIMARY KEY, created_by TEXT NOT NULL, product_ids TEXT NOT NULL,
      daily_budget_cents INTEGER NOT NULL, max_cpc_cents INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'active', created INTEGER NOT NULL, updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS ad_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, brand_id TEXT NOT NULL, product_id TEXT NOT NULL,
      kind TEXT NOT NULL, placement TEXT, viewer TEXT NOT NULL, cost_cents INTEGER NOT NULL DEFAULT 0,
      day TEXT NOT NULL, created INTEGER NOT NULL, billed INTEGER);
    CREATE INDEX IF NOT EXISTS ad_events_brand_day ON ad_events(brand_id, day);
    CREATE INDEX IF NOT EXISTS ad_events_viewer ON ad_events(viewer, created);
    CREATE TABLE IF NOT EXISTS ad_billing (
      brand_id TEXT PRIMARY KEY, customer TEXT, payment_method TEXT, card TEXT,
      failed TEXT, last_charged INTEGER, updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS ad_charges (
      id TEXT PRIMARY KEY, brand_id TEXT NOT NULL, amount_cents INTEGER NOT NULL,
      status TEXT NOT NULL, stripe_id TEXT, created INTEGER NOT NULL);`);
  const has = (t, c) => db.prepare(`SELECT 1 FROM pragma_table_info('${t}') WHERE name=?`).get(c);
  // approval: pending | approved | rejected (owner's call).
  if (!has("ad_campaigns", "approval")) db.exec("ALTER TABLE ad_campaigns ADD COLUMN approval TEXT NOT NULL DEFAULT 'pending'");
  // ip: hashed client IP; imp: the impression nonce a charged tap used.
  if (!has("ad_events", "ip")) db.exec("ALTER TABLE ad_events ADD COLUMN ip TEXT");
  if (!has("ad_events", "imp")) db.exec("ALTER TABLE ad_events ADD COLUMN imp TEXT");
  db.exec("CREATE INDEX IF NOT EXISTS ad_events_ip ON ad_events(ip, created); CREATE INDEX IF NOT EXISTS ad_events_imp ON ad_events(imp)");
}

// Signed impression ids: /serve hands one out per item, /tap must bring it
// back to be charged.
const b64 = (v) => Buffer.from(v).toString("base64url");
/// `viewer` (the hashed viewer /serve showed it to) is signed in, so an
/// impression collected under one identity can't be spent under another
/// (2026-11-12).
export function signImpression(key, { brandID, productID, placement, now, viewer = null }) {
  const body = b64(JSON.stringify({ b: brandID, p: productID, pl: placement, t: now, n: randomBytes(9).toString("hex"), ...(viewer ? { v: viewer } : {}) }));
  return `${body}.${createHmac("sha256", key).update(body).digest("base64url")}`;
}
export function readImpression(key, token, { brandID, productID, now, viewer = null }) {
  if (typeof token !== "string" || token.length > 600) return null;
  const [body, sig] = token.split(".");
  if (!body || !sig) return null;
  const want = Buffer.from(createHmac("sha256", key).update(body).digest("base64url")), got = Buffer.from(sig);
  if (want.length !== got.length || !timingSafeEqual(want, got)) return null;
  let imp;
  try { imp = JSON.parse(Buffer.from(body, "base64url").toString("utf8")); } catch { return null; }
  if (imp.b !== brandID || imp.p !== productID || !(now - imp.t >= 0 && now - imp.t <= IMPRESSION_TTL_MS)) return null;
  if (viewer && imp.v !== viewer) return null;
  return imp;
}

const dayOf = (ms) => new Date(ms).toISOString().slice(0, 10);
export const manages = (db, userID, brandID) =>
  !!userID && !!db.prepare("SELECT 1 FROM brand_admins WHERE brand_id=? AND user_id=?").get(brandID, userID);

const spentToday = (db, brandID, now) =>
  db.prepare("SELECT COALESCE(SUM(cost_cents),0) AS c FROM ad_events WHERE brand_id=? AND day=?").get(brandID, dayOf(now)).c;
const owed = (db, brandID) =>
  db.prepare("SELECT COALESCE(SUM(cost_cents),0) AS c FROM ad_events WHERE brand_id=? AND billed IS NULL AND cost_cents>0").get(brandID).c;

/// Campaigns that can show now: active, a working card, budget left today.
export function liveCampaigns(db, now) {
  return db.prepare(`SELECT c.* FROM ad_campaigns c JOIN ad_billing b ON b.brand_id=c.brand_id
      WHERE c.status='active' AND c.approval='approved' AND b.payment_method IS NOT NULL AND b.failed IS NULL`).all()
    .filter((c) => spentToday(db, c.brand_id, now) + MIN_CPC_CENTS <= c.daily_budget_cents)
    .map((c) => ({ ...c, products: JSON.parse(c.product_ids) }));
}

const words = (s) => String(s || "").toLowerCase().match(/[a-z0-9]+/g) || [];

/// How well a product fits a placement, 0 (not at all) to 1.
export function relevance(product, { placement, q, category, near }) {
  if (!product?.available) return 0;
  if (placement === "search") {
    const want = words(q).filter((w) => w.length > 1);
    if (!want.length) return 0;
    const have = new Set(words(`${product.title} ${product.product_type || ""} ${(product.tags || []).join(" ")}`));
    const hits = want.filter((w) => have.has(w) || have.has(w.replace(/s$/, ""))).length;
    return hits / want.length;
  }
  if (placement === "category") return product.category === category ? 1 : 0;
  if (placement === "product") {
    if (!near || near.id === product.id || near.brand === product.brand) return 0;
    if (product.category !== near.category) return 0;
    const shared = (near.subs || []).filter((s) => (product.subs || []).includes(s)).length;
    return shared ? 1 : 0.5;
  }
  return 0;
}

/// The sponsored products for one placement: the best product of each
/// campaign that fits, highest bid x fit first, at most `limit`.
export function pick(campaigns, ctx, limit, lookup = productRecord) {
  const ranked = [];
  for (const c of campaigns) {
    let best = null;
    for (const id of c.products) {
      const p = lookup(id);
      const fit = relevance(p, ctx);
      if (fit >= 0.5 && (!best || fit > best.fit)) best = { productID: id, fit };
    }
    if (best) ranked.push({ brandID: c.brand_id, productID: best.productID, score: c.max_cpc_cents * best.fit, bid: c.max_cpc_cents });
  }
  ranked.sort((a, b) => b.score - a.score);
  return ranked.slice(0, limit);
}

/// What a tap costs: a cent over the next bid for that kind of product, at
/// least the floor, never above the brand's own cap.
export function tapPrice(campaign, others) {
  const next = Math.max(0, ...others.map((o) => o.max_cpc_cents).filter((b) => b <= campaign.max_cpc_cents));
  return Math.min(campaign.max_cpc_cents, Math.max(MIN_CPC_CENTS, next + 1));
}

/// Records a tap and what it costs (0 when it doesn't count). `impression`
/// is the verified impression from /serve (null: never charged); `ip` the
/// hashed client IP.
export function recordTap(db, { brandID, productID, placement, viewer, userID, now, impression = null, ip = null }) {
  const c = db.prepare("SELECT * FROM ad_campaigns WHERE brand_id=?").get(brandID);
  const p = productRecord(productID);
  if (!c || !p || p.brand !== brandID || !JSON.parse(c.product_ids).includes(productID)) return null;
  const day = dayOf(now);
  let cost = 0;
  const own = manages(db, userID, brandID);
  const again = db.prepare("SELECT 1 FROM ad_events WHERE viewer=? AND product_id=? AND kind='tap' AND day=?").get(viewer, productID, day);
  const burst = db.prepare("SELECT COUNT(*) AS n FROM ad_events WHERE viewer=? AND kind='tap' AND created>?").get(viewer, now - 3600_000).n >= TAPS_PER_HOUR;
  const reused = impression && db.prepare("SELECT 1 FROM ad_events WHERE imp=?").get(impression.n);
  const ipDay = ip && db.prepare("SELECT COUNT(*) AS n FROM ad_events WHERE ip=? AND kind='tap' AND cost_cents>0 AND created>?").get(ip, now - 86400_000).n;
  const ipAgain = ip && db.prepare("SELECT 1 FROM ad_events WHERE ip=? AND product_id=? AND kind='tap' AND cost_cents>0 AND day=?").get(ip, productID, day);
  if (c.status === "active" && c.approval === "approved" && impression && !reused && ip && ipDay < TAPS_PER_IP_DAY && !ipAgain && !own && !again && !burst) {
    const others = liveCampaigns(db, now).filter((o) => o.brand_id !== brandID &&
      o.products.some((id) => productRecord(id)?.category === p.category));
    const price = tapPrice(c, others);
    if (spentToday(db, brandID, now) + price <= c.daily_budget_cents) cost = price;
  }
  db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,placement,viewer,cost_cents,day,created,ip,imp) VALUES(?,?,'tap',?,?,?,?,?,?,?)")
    .run(brandID, productID, placement || null, viewer, cost, day, now, ip, impression && !reused ? impression.n : null);
  return cost;
}

export function stats(db, brandID, now) {
  const since = dayOf(now - 6 * 86400_000);
  const row = db.prepare(`SELECT SUM(kind='view') AS views, SUM(kind='tap') AS taps, COALESCE(SUM(cost_cents),0) AS spent
    FROM ad_events WHERE brand_id=? AND day>=?`).get(brandID, since);
  return { views: row.views || 0, taps: row.taps || 0, spentCents: row.spent, todayCents: spentToday(db, brandID, now), owedCents: owed(db, brandID) };
}

/// Charges each brand that owes $25, or anything owed for a week. A failed
/// charge pauses the brand's ads until a new card is saved.
///
/// A charge can never be made twice for the same taps (2026-11-12). Each
/// carries an idempotency key made from the brand, the last tap it covers and
/// the card: if Stripe took the money but its answer never arrived, the next
/// run sends the same key and gets that same payment back. Such an
/// unanswered attempt is retried, not counted as a failed card; and one run
/// at a time works on a database.
const charging = new WeakSet();
export async function chargeDue(db, options = {}) {
  if (charging.has(db)) return 0;
  charging.add(db);
  try { return await chargeEach(db, options); } finally { charging.delete(db); }
}
async function chargeEach(db, { env, fetcher = fetch, now = Date.now, log = console.log } = {}) {
  let charged = 0;
  for (const b of db.prepare("SELECT * FROM ad_billing WHERE payment_method IS NOT NULL AND failed IS NULL").all()) {
    const amount = owed(db, b.brand_id);
    if (amount < 50 || (amount < BILL_AT_CENTS && now() - (b.last_charged || b.updated) < WEEK_MS)) continue;
    const id = randomBytes(9).toString("hex");
    const cutoff = db.prepare("SELECT MAX(id) AS m FROM ad_events WHERE brand_id=? AND billed IS NULL").get(b.brand_id).m;
    try {
      const pi = await stripe(env, "POST", "payment_intents", {
        amount: String(amount), currency: "usd", customer: b.customer, payment_method: b.payment_method,
        off_session: "true", confirm: "true", description: `Marracat sponsored products: ${b.brand_id}`,
        "metadata[brand]": b.brand_id, "metadata[charge]": id,
      }, fetcher, { idempotencyKey: sha(`ad-charge:${b.brand_id}:${cutoff}:${b.payment_method}`) });
      db.transaction(() => {
        db.prepare("INSERT INTO ad_charges(id,brand_id,amount_cents,status,stripe_id,created) VALUES(?,?,?,?,?,?)").run(id, b.brand_id, amount, pi.status, pi.id, now());
        db.prepare("UPDATE ad_events SET billed=? WHERE brand_id=? AND billed IS NULL AND id<=?").run(now(), b.brand_id, cutoff);
        db.prepare("UPDATE ad_billing SET last_charged=? WHERE brand_id=?").run(now(), b.brand_id);
      })();
      charged++;
    } catch (e) {
      if (!e.answered) { log(`Sponsored charge for ${b.brand_id} got no answer (${e.name}); it is tried again next run`); continue; }
      log(`Sponsored charge failed for ${b.brand_id}: ${e.message}`);
      db.prepare("INSERT INTO ad_charges(id,brand_id,amount_cents,status,created) VALUES(?,?,?,'failed',?)").run(id, b.brand_id, amount, now());
      db.prepare("UPDATE ad_billing SET failed=? WHERE brand_id=?").run(String(e.message).slice(0, 200), b.brand_id);
    }
  }
  return charged;
}

export function sponsoredRoutes(app, db, { env = process.env, viewer = (req) => viewerOf(req, db, env), fetcher = fetch, now = Date.now, schedule = env.NODE_ENV === "production" } = {}) {
  installSponsoredSchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "16kb" }));
  const testMode = () => !String(env.STRIPE_SECRET_KEY || "").startsWith("sk_live_");
  const site = env.PUBLIC_URL || "https://marracat.com";
  // Who's looking: the device key (app) or a browser id, hashed; never raw.
  const viewerKey = (req) => {
    const key = req.get("X-Marracat-Device") || req.get("X-Marracat-Visitor") || req.ip || "anon";
    return sha("ads:" + key);
  };
  const who = async (req) => (await viewer(req).catch(() => null)) || null;
  const ipKey = (req) => (req.ip ? sha("ads-ip:" + req.ip) : null);
  const impressionKey = env.ADS_IMPRESSION_KEY || (env.AUTH_SECRET ? sha("ads-impressions:" + env.AUTH_SECRET) : randomBytes(32).toString("hex"));

  // ---- shoppers: what to show, and taps -----------------------------------
  router.get("/serve", async (req, res) => {
    const user = await who(req);
    if (testMode() && !(user && isOwnerEmail(user.email))) return res.json({ items: [] });
    const placement = String(req.query.placement || "");
    if (!["search", "category", "product"].includes(placement)) return res.status(400).json({ error: "Unknown placement" });
    const near = placement === "product" ? productRecord(String(req.query.product || "")) : null;
    const ctx = { placement, q: String(req.query.q || "").slice(0, 120), category: String(req.query.category || ""), near };
    const limit = placement === "search" ? 2 : placement === "product" ? 6 : 1;
    const items = pick(liveCampaigns(db, now()), ctx, limit);
    const v = viewerKey(req), day = dayOf(now());
    for (const it of items)
      if (!db.prepare("SELECT 1 FROM ad_events WHERE viewer=? AND product_id=? AND kind='view' AND day=?").get(v, it.productID, day))
        db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,placement,viewer,day,created) VALUES(?,?,'view',?,?,?,?)").run(it.brandID, it.productID, placement, v, day, now());
    res.json({ items: items.map(({ brandID, productID }) => ({ brandID, productID,
      impression: signImpression(impressionKey, { brandID, productID, placement, now: now(), viewer: v }) })) });
  });
  router.post("/tap", async (req, res) => {
    const user = await who(req);
    const brandID = String(req.body?.brandID || ""), productID = String(req.body?.productID || "");
    // Old app builds send no impression: their taps are recorded, not charged.
    const impression = readImpression(impressionKey, req.body?.impression, { brandID, productID, now: now(), viewer: viewerKey(req) });
    const cost = recordTap(db, { brandID, productID, placement: String(req.body?.placement || "").slice(0, 20),
      viewer: viewerKey(req), userID: user?.id, now: now(), impression, ip: ipKey(req) });
    res.sendStatus(cost == null ? 404 : 204);
  });

  // ---- brands: their campaigns ---------------------------------------------
  const brandUser = async (req, res) => {
    const user = await who(req);
    if (!user) { res.status(401).json({ error: "Sign in first." }); return null; }
    return user;
  };
  const view = (brandID) => {
    const c = db.prepare("SELECT * FROM ad_campaigns WHERE brand_id=?").get(brandID);
    const b = db.prepare("SELECT card, failed FROM ad_billing WHERE brand_id=?").get(brandID);
    const brand = brandRecord(brandID);
    return {
      brand: { id: brandID, name: brand?.name || brandID },
      campaign: c ? { productIDs: JSON.parse(c.product_ids), dailyBudget: c.daily_budget_cents / 100, maxCPC: c.max_cpc_cents / 100, status: c.status, approval: c.approval } : null,
      card: b?.card || null, cardProblem: b?.failed || null, stats: stats(db, brandID, now()), test: testMode(),
    };
  };
  router.get("/brands", async (req, res) => {
    const user = await brandUser(req, res);
    if (!user) return;
    const ids = db.prepare("SELECT brand_id FROM brand_admins WHERE user_id=?").all(user.id).map((r) => r.brand_id);
    res.json({ brands: ids.map(view) });
  });
  router.put("/campaign", async (req, res) => {
    const user = await brandUser(req, res);
    if (!user) return;
    const brandID = String(req.body?.brand || "");
    if (!manages(db, user.id, brandID)) return res.status(403).json({ error: "Verify that you manage this brand first." });
    const ids = Array.isArray(req.body?.productIDs) ? [...new Set(req.body.productIDs.map(String))].slice(0, MAX_PRODUCTS) : [];
    if (!ids.length || !ids.every((id) => productRecord(id)?.brand === brandID)) return res.status(400).json({ error: "Pick products from your own brand." });
    const budget = Math.round(Number(req.body?.dailyBudget) * 100), cpc = Math.round(Number(req.body?.maxCPC) * 100);
    if (!(budget >= MIN_BUDGET_CENTS && budget <= MAX_BUDGET_CENTS)) return res.status(400).json({ error: "Daily budget is $5 to $500." });
    if (!(cpc >= MIN_CPC_CENTS && cpc <= MAX_CPC_CENTS && cpc <= budget)) return res.status(400).json({ error: "Most per tap is $0.20 to $5." });
    // New products (or a new campaign) wait for the owner's approval again.
    const before = db.prepare("SELECT product_ids FROM ad_campaigns WHERE brand_id=?").get(brandID);
    const sameProducts = before && JSON.stringify([...JSON.parse(before.product_ids)].sort()) === JSON.stringify([...ids].sort());
    db.prepare(`INSERT INTO ad_campaigns(brand_id,created_by,product_ids,daily_budget_cents,max_cpc_cents,status,created,updated,approval) VALUES(?,?,?,?,?,'active',?,?,'pending')
      ON CONFLICT(brand_id) DO UPDATE SET product_ids=excluded.product_ids, daily_budget_cents=excluded.daily_budget_cents,
        max_cpc_cents=excluded.max_cpc_cents, updated=excluded.updated,
        approval=CASE WHEN ? THEN ad_campaigns.approval ELSE 'pending' END`).run(brandID, user.id, JSON.stringify(ids), budget, cpc, now(), now(), sameProducts ? 1 : 0);
    res.json(view(brandID));
  });
  router.post("/campaign/status", async (req, res) => {
    const user = await brandUser(req, res);
    if (!user) return;
    const brandID = String(req.body?.brand || ""), status = req.body?.status;
    if (!manages(db, user.id, brandID)) return res.status(403).json({ error: "Verify that you manage this brand first." });
    if (!["active", "paused"].includes(status)) return res.status(400).json({ error: "Unknown status" });
    const r = db.prepare("UPDATE ad_campaigns SET status=?, updated=? WHERE brand_id=?").run(status, now(), brandID);
    if (!r.changes) return res.status(404).json({ error: "Set up your ads first." });
    res.json(view(brandID));
  });

  // The owner's review queue: approve or reject a campaign before it shows.
  const ownerOnly = async (req, res) => {
    const user = await brandUser(req, res);
    if (!user) return null;
    if (!isOwnerEmail(user.email)) { res.sendStatus(403); return null; }
    return user;
  };
  router.get("/admin/campaigns", async (req, res) => {
    if (!(await ownerOnly(req, res))) return;
    res.json({ campaigns: db.prepare("SELECT brand_id FROM ad_campaigns ORDER BY approval='pending' DESC, updated DESC LIMIT 200").all().map((r) => view(r.brand_id)) });
  });
  router.post("/admin/approve", async (req, res) => {
    if (!(await ownerOnly(req, res))) return;
    const brandID = String(req.body?.brand || "");
    const approval = req.body?.approve === true ? "approved" : req.body?.approve === false ? "rejected" : null;
    if (!approval) return res.status(400).json({ error: "approve must be true or false" });
    const r = db.prepare("UPDATE ad_campaigns SET approval=?, updated=? WHERE brand_id=?").run(approval, now(), brandID);
    if (!r.changes) return res.status(404).json({ error: "No such campaign" });
    res.json(view(brandID));
  });

  // A card for the brand's taps: Stripe Checkout in setup mode (on the website).
  router.post("/billing/setup", async (req, res) => {
    const user = await brandUser(req, res);
    if (!user) return;
    const brandID = String(req.body?.brand || "");
    if (!manages(db, user.id, brandID)) return res.status(403).json({ error: "Verify that you manage this brand first." });
    if (!env.STRIPE_SECRET_KEY) return res.status(503).json({ error: "Payments aren't available yet." });
    try {
      let b = db.prepare("SELECT * FROM ad_billing WHERE brand_id=?").get(brandID);
      if (!b?.customer) {
        const customer = await stripe(env, "POST", "customers", { email: user.email || "", name: brandRecord(brandID)?.name || brandID, "metadata[brand]": brandID }, fetcher);
        db.prepare(`INSERT INTO ad_billing(brand_id,customer,updated) VALUES(?,?,?) ON CONFLICT(brand_id) DO UPDATE SET customer=excluded.customer, updated=excluded.updated`).run(brandID, customer.id, now());
        b = db.prepare("SELECT * FROM ad_billing WHERE brand_id=?").get(brandID);
      }
      const session = await stripe(env, "POST", "checkout/sessions", {
        mode: "setup", customer: b.customer, currency: "usd", "payment_method_types[0]": "card",
        success_url: `${site}/#/brand-ads?brand=${encodeURIComponent(brandID)}&setup={CHECKOUT_SESSION_ID}`,
        cancel_url: `${site}/#/brand-ads?brand=${encodeURIComponent(brandID)}`,
        "metadata[brand]": brandID,
      }, fetcher);
      res.status(201).json({ url: session.url });
    } catch (e) { res.status(502).json({ error: "Stripe didn't answer. Try again." }); }
  });
  // Back from Stripe: read the saved card off the session.
  router.post("/billing/confirm", async (req, res) => {
    const user = await brandUser(req, res);
    if (!user) return;
    const brandID = String(req.body?.brand || ""), sid = String(req.body?.session || "");
    if (!manages(db, user.id, brandID)) return res.status(403).json({ error: "Verify that you manage this brand first." });
    if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(sid)) return res.status(400).json({ error: "Unknown session" });
    try {
      const s = await stripe(env, "GET", `checkout/sessions/${sid}?expand[]=setup_intent.payment_method`, null, fetcher);
      const b = db.prepare("SELECT customer FROM ad_billing WHERE brand_id=?").get(brandID);
      const pm = s.setup_intent?.payment_method;
      if (s.metadata?.brand !== brandID || s.customer !== b?.customer || !pm?.id) return res.status(400).json({ error: "That card setup didn't finish." });
      const card = pm.card ? `${pm.card.brand} ending ${pm.card.last4}` : "Card";
      db.prepare("UPDATE ad_billing SET payment_method=?, card=?, failed=NULL, updated=? WHERE brand_id=?").run(pm.id, card, now(), brandID);
      res.json(view(brandID));
    } catch { res.status(502).json({ error: "Stripe didn't answer. Try again." }); }
  });

  router.use((error, req, res, next) => res.status(error.type === "entity.parse.failed" ? 400 : 500).json({ error: "Request could not be completed" }));
  app.use("/api/ads", router);

  if (schedule) {
    const run = () => chargeDue(db, { env, fetcher, now }).then((n) => n && console.log(`Sponsored: ${n} brands charged`)).catch((e) => console.error("Sponsored billing failed:", e.name));
    setInterval(run, 3600_000).unref();
  }
}
