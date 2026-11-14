// Monthly boost budgets: a verified brand sets what to promote, which boost to
// run and how much to spend a month; Stripe bills it monthly and Marracat runs
// that boost back-to-back until the month's money is used (owner, 2026-10-10:
// "allow brands to create recurring payments so they can set a budget").
//
//  - Only an account in brand_admins for that brand (brand-claims.js) can set
//    one up, and only for its own brand page or products. While Stripe is in
//    test mode the owner alone can use it, and its boosts never show publicly
//    (same gate as boosts.js).
//  - Billing: Stripe Checkout in subscription mode with an inline monthly
//    price; amounts come from the server, never the browser. Each paid invoice
//    (invoice.paid) credits the budget once; a failed payment pauses spending
//    until a later invoice is paid; a canceled plan spends what was already
//    paid, then stops.
//  - Spending: one boost at a time for the target, each the best tier the
//    balance covers among the placements the brand picked, starting when the
//    last one ends. Spend never exceeds what was paid. A balance too small for
//    any tier (under $5) carries into the next month.
//  - Every boost it runs is a normal row in `boosts` (budget_id set), so the
//    carousel's reserved slots, rotation, "Sponsored" label and seen/tapped
//    counts work exactly as for one-off boosts.
import express from "express";
import { randomBytes } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { TIERS, stripe, installBoostSchema } from "./boosts.js";
import { brandRecord, productRecord } from "./catalog.js";
import { isOwnerEmail } from "./owner-metrics.js";
import { localDay } from "./visits.js";

const DAY_MS = 86400_000;
export const MIN_MONTHLY_DOLLARS = 5;
/// The most one target can usefully spend in a month: its chosen boost run
/// back-to-back for 31 days. Spotlight ($100 / 7 days) tops out at $500.
export function monthlyCap(tier) {
  const t = TIERS[tier];
  return t ? Math.ceil(31 / t.days) * tier : 0;
}
/// Tiers a plan may run: its chosen tier and any cheaper one whose placements
/// are all among the chosen tier's (Spotlight -> all; Boost -> Boost only).
export function allowedTiers(tier) {
  const places = TIERS[tier]?.places || [];
  return Object.keys(TIERS).map(Number).filter((t) => t <= tier && TIERS[t].places.every((p) => places.includes(p)))
    .sort((a, b) => b - a);
}

export function installBudgetSchema(db) {
  installBoostSchema(db);
  try { db.exec("ALTER TABLE boosts ADD COLUMN budget_id TEXT"); } catch { /* already there */ }
  db.exec(`
    CREATE TABLE IF NOT EXISTS boost_budgets (
      id TEXT PRIMARY KEY, brand_id TEXT NOT NULL, user_id TEXT NOT NULL, target TEXT NOT NULL,
      tier INTEGER NOT NULL, monthly_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
      session TEXT UNIQUE, subscription TEXT UNIQUE, customer TEXT, item TEXT, period_end INTEGER,
      live INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL, updated INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS boost_budgets_brand ON boost_budgets(brand_id, status);
    CREATE TABLE IF NOT EXISTS boost_budget_credits (
      invoice TEXT PRIMARY KEY, budget_id TEXT NOT NULL, cents INTEGER NOT NULL,
      period_start INTEGER, period_end INTEGER, paid INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS stripe_events (id TEXT PRIMARY KEY, type TEXT NOT NULL, received INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS boosts_budget ON boosts(budget_id, ends);`);
}

/// Paid in, spent, and what's left on a plan.
export function balance(db, budgetID) {
  const paid = db.prepare("SELECT COALESCE(SUM(cents),0) AS c FROM boost_budget_credits WHERE budget_id=?").get(budgetID).c;
  const spent = db.prepare("SELECT COALESCE(SUM(amount_cents),0) AS c FROM boosts WHERE budget_id=? AND status='paid'").get(budgetID).c;
  return { paid, spent, left: paid - spent };
}

/// Starts the next boost for every plan that has money and nothing queued.
/// Runs on a timer and right after a payment; safe to call any time.
export function allocateBudgets(db, now = Date.now(), lookup = { productRecord, brandRecord }) {
  const started = [];
  const plans = db.prepare("SELECT * FROM boost_budgets WHERE status IN ('active','canceled')").all();
  const insert = db.prepare(`INSERT INTO boosts(id,target,tier,amount_cents,user_id,status,session,created,starts,ends,live,budget_id)
    VALUES(?,?,?,?,?,'paid',NULL,?,?,?,?,?)`);
  for (const plan of plans) {
    // Queue the next one shortly before the current one ends, so runs are back-to-back.
    const last = db.prepare("SELECT MAX(ends) AS ends FROM boosts WHERE budget_id=? AND status='paid'").get(plan.id).ends || 0;
    if (last > now + 15 * 60_000) continue;
    // A product that's gone runs as its brand page (activeBoosts does the same for sold-out ones).
    if (plan.target.startsWith("product:") && !lookup.productRecord(plan.target.slice(8))) continue;
    const { left } = balance(db, plan.id);
    const tier = allowedTiers(plan.tier).find((t) => t * 100 <= left);
    if (!tier) continue;
    const starts = Math.max(now, last);
    const id = "bb" + randomBytes(8).toString("hex");
    insert.run(id, plan.target, tier, tier * 100, plan.user_id, now, starts, starts + TIERS[tier].days * DAY_MS, plan.live, plan.id);
    started.push({ id, budget: plan.id, tier });
  }
  return started;
}

// ---- Stripe webhook events -------------------------------------------------

/// Records the event id; false when it was already handled (Stripe retries).
export function firstDelivery(db, event, now = Date.now()) {
  if (!event?.id) return false;
  return db.prepare("INSERT OR IGNORE INTO stripe_events(id,type,received) VALUES(?,?,?)").run(String(event.id), String(event.type || ""), now).changes === 1;
}

// The subscription id and our budget id from an invoice, across API versions
// (2025+ moved them under parent.subscription_details).
const invoiceSubscription = (inv) => inv?.parent?.subscription_details?.subscription || inv?.subscription || null;
const invoiceBudget = (inv) => inv?.parent?.subscription_details?.metadata?.budget || inv?.subscription_details?.metadata?.budget || null;
const subscriptionPeriodEnd = (sub) => (sub?.items?.data?.[0]?.current_period_end || sub?.current_period_end || 0) * 1000 || null;

function planForInvoice(db, inv) {
  const sub = invoiceSubscription(inv);
  let plan = sub && db.prepare("SELECT * FROM boost_budgets WHERE subscription=?").get(sub);
  if (!plan) {
    const id = invoiceBudget(inv);
    plan = id && db.prepare("SELECT * FROM boost_budgets WHERE id=?").get(id);
    if (plan && sub && !plan.subscription) db.prepare("UPDATE boost_budgets SET subscription=? WHERE id=?").run(sub, plan.id);
  }
  return plan || null;
}

/// Credits a paid invoice to its plan, once (keyed by invoice id).
export function creditInvoice(db, inv, now = Date.now()) {
  const plan = planForInvoice(db, inv);
  if (!plan || !inv?.id || !(inv.amount_paid > 0)) return null;
  const line = inv.lines?.data?.[0]?.period || {};
  const r = db.prepare("INSERT OR IGNORE INTO boost_budget_credits(invoice,budget_id,cents,period_start,period_end,paid) VALUES(?,?,?,?,?,?)")
    .run(inv.id, plan.id, inv.amount_paid, (line.start || 0) * 1000 || null, (line.end || 0) * 1000 || null, now);
  // A paid invoice brings a paused (past-due) plan back.
  db.prepare("UPDATE boost_budgets SET status=CASE WHEN status IN ('pending','past_due') THEN 'active' ELSE status END, period_end=COALESCE(?, period_end), updated=? WHERE id=?")
    .run((line.end || 0) * 1000 || null, now, plan.id);
  return r.changes ? plan.id : null;
}

/// Applies one verified Stripe event to the plans. Returns true if it touched one.
export function handleBudgetEvent(db, event, now = Date.now()) {
  const o = event?.data?.object;
  if (!o) return false;
  switch (event.type) {
    case "checkout.session.completed": {
      if (o.mode !== "subscription") return false;
      const plan = db.prepare("SELECT * FROM boost_budgets WHERE session=?").get(o.id);
      if (!plan) return false;
      db.prepare("UPDATE boost_budgets SET subscription=COALESCE(subscription,?), customer=?, status=CASE WHEN status='pending' THEN 'active' ELSE status END, updated=? WHERE id=?")
        .run(o.subscription || null, o.customer || null, now, plan.id);
      return true;
    }
    case "invoice.paid":
      return !!creditInvoice(db, o, now);
    case "invoice.payment_failed": {
      const plan = planForInvoice(db, o);
      if (!plan) return false;
      db.prepare("UPDATE boost_budgets SET status='past_due', updated=? WHERE id=? AND status IN ('active','pending')").run(now, plan.id);
      return true;
    }
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const plan = db.prepare("SELECT * FROM boost_budgets WHERE subscription=?").get(o.id)
        || (o.metadata?.budget && db.prepare("SELECT * FROM boost_budgets WHERE id=?").get(o.metadata.budget));
      if (!plan) return false;
      const status = event.type === "customer.subscription.deleted" || o.status === "canceled" ? "canceled"
        : ["past_due", "unpaid", "incomplete", "incomplete_expired", "paused"].includes(o.status) ? "past_due"
        : o.status === "active" || o.status === "trialing" ? "active" : plan.status;
      db.prepare("UPDATE boost_budgets SET status=?, subscription=COALESCE(subscription,?), item=COALESCE(?, item), period_end=COALESCE(?, period_end), updated=? WHERE id=?")
        .run(status, o.id, o.items?.data?.[0]?.id || null, subscriptionPeriodEnd(o), now, plan.id);
      return true;
    }
    default:
      return false;
  }
}

// ---- Routes ----------------------------------------------------------------

export function budgetRoutes(app, db, { env = process.env, viewer = async () => null, fetcher = fetch, now = Date.now,
  lookup = { productRecord, brandRecord }, schedule = true } = {}) {
  installBudgetSchema(db);
  const router = express.Router();
  router.use(express.json({ limit: "4kb" }));
  router.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  const site = env.PUBLIC_URL || "https://marracat.com";
  const testMode = () => !String(env.STRIPE_SECRET_KEY || "").startsWith("sk_live_");
  const admin = (userID, brandID) => !!db.prepare("SELECT 1 FROM brand_admins WHERE brand_id=? AND user_id=?").get(brandID, userID);

  // Signed in, and allowed to manage this brand's money: a verified admin of
  // it once Stripe is live; in test mode only the owner (who can test any brand).
  const manager = async (req, res, brandID) => {
    const user = await viewer(req).catch(() => null);
    if (!user) { res.status(401).json({ error: "Sign in first." }); return null; }
    if (!env.STRIPE_SECRET_KEY) { res.status(503).json({ error: "Budgets aren't available yet." }); return null; }
    const owner = isOwnerEmail(user.email);
    if (testMode() && !owner) { res.status(503).json({ error: "Budgets aren't available yet." }); return null; }
    if (!lookup.brandRecord(brandID)) { res.status(404).json({ error: "That brand isn't on Marracat." }); return null; }
    if (!admin(user.id, brandID) && !(testMode() && owner)) { res.status(403).json({ error: "Verify that you manage this brand first." }); return null; }
    return user;
  };

  // What a plan looks like to its brand: balance, this month, seen and tapped.
  const view = (plan) => {
    if (!plan) return null;
    const b = balance(db, plan.id);
    const monthStart = now() - 30 * DAY_MS;
    const runs = db.prepare("SELECT tier, amount_cents, starts, ends FROM boosts WHERE budget_id=? AND status='paid' ORDER BY starts DESC LIMIT 60").all(plan.id);
    const spentMonth = runs.filter((r) => r.starts >= monthStart).reduce((s, r) => s + r.amount_cents, 0);
    const stats = Object.fromEntries(db.prepare("SELECT kind, COUNT(*) AS n FROM boost_events WHERE target=? AND day>=? GROUP BY kind")
      .all(plan.target, localDay(monthStart)).map((r) => [r.kind, r.n]));
    return {
      id: plan.id, status: plan.status, test: !plan.live, target: plan.target, tier: plan.tier,
      label: TIERS[plan.tier]?.label, monthly: plan.monthly_cents / 100, nextCharge: plan.period_end,
      paid: b.paid / 100, spent: b.spent / 100, left: b.left / 100, spentLast30: spentMonth / 100,
      running: runs.find((r) => r.starts <= now() && r.ends > now()) || null,
      runs: runs.slice(0, 12).map((r) => ({ tier: r.tier, label: TIERS[r.tier]?.label, dollars: r.amount_cents / 100, starts: r.starts, ends: r.ends })),
      views: stats.view || 0, taps: stats.tap || 0,
    };
  };
  const current = (brandID) => db.prepare("SELECT * FROM boost_budgets WHERE brand_id=? AND status IN ('active','past_due','pending','canceled') ORDER BY CASE status WHEN 'active' THEN 0 WHEN 'past_due' THEN 1 WHEN 'pending' THEN 2 ELSE 3 END, created DESC LIMIT 1").get(brandID);

  // The choices, with each boost's monthly range.
  router.get("/options", (_req, res) => res.json(Object.entries(TIERS).map(([d, t]) => ({
    tier: Number(d), label: t.label, days: t.days, places: t.places, min: Math.max(MIN_MONTHLY_DOLLARS, Number(d)), max: monthlyCap(Number(d)),
  }))));

  router.get("/", async (req, res) => {
    const brandID = String(req.query.brand || "");
    if (!(await manager(req, res, brandID))) return;
    res.set("Cache-Control", "private, no-store");
    res.json({ plan: view(current(brandID)) });
  });

  // Validates a plan request; every number is recomputed here.
  const parse = (body, brandID) => {
    const tier = Number(body?.tier);
    if (!TIERS[tier]) return { error: "Pick Spark, Boost, Big boost or Spotlight." };
    const dollars = Number(body?.dollars);
    const min = Math.max(MIN_MONTHLY_DOLLARS, tier), max = monthlyCap(tier);
    if (!Number.isInteger(dollars) || dollars < min || dollars > max)
      return { error: `${TIERS[tier].label} budgets are $${min} to $${max} a month, in whole dollars.` };
    let target = null;
    if (body?.type === "brand" && String(body?.id) === brandID) target = `brand:${brandID}`;
    if (body?.type === "product") {
      const p = lookup.productRecord(String(body?.id || ""));
      if (p && p.brand === brandID) target = `product:${p.id}`;
    }
    if (!target) return { error: "Promote your brand page or one of your own products." };
    return { tier, cents: dollars * 100, target };
  };

  // One Stripe product for every plan's monthly price (created once per mode).
  db.exec("CREATE TABLE IF NOT EXISTS stripe_objects (key TEXT PRIMARY KEY, id TEXT NOT NULL)");
  const budgetProduct = async () => {
    const key = `budget-product:${testMode() ? "test" : "live"}`;
    const known = db.prepare("SELECT id FROM stripe_objects WHERE key=?").get(key);
    if (known) return known.id;
    const p = await stripe(env, "POST", "products", { name: "Marracat monthly boost budget",
      description: "Sponsored placement on Marracat, billed monthly and labeled \"Sponsored\"." }, fetcher);
    db.prepare("INSERT OR REPLACE INTO stripe_objects(key,id) VALUES(?,?)").run(key, p.id);
    return p.id;
  };

  // The billing page's settings (card, invoices, cancel at period end), created
  // once per mode the first time a brand opens it; STRIPE_PORTAL_CONFIG overrides.
  const portalConfig = async () => {
    if (env.STRIPE_PORTAL_CONFIG) return env.STRIPE_PORTAL_CONFIG;
    const key = `portal-config:${testMode() ? "test" : "live"}`;
    const known = db.prepare("SELECT id FROM stripe_objects WHERE key=?").get(key);
    if (known) return known.id;
    const c = await stripe(env, "POST", "billing_portal/configurations", {
      "business_profile[headline]": "Marracat boost budget",
      "business_profile[privacy_policy_url]": `${site}/privacy`,
      "features[invoice_history][enabled]": "true",
      "features[payment_method_update][enabled]": "true",
      "features[subscription_cancel][enabled]": "true",
      "features[subscription_cancel][mode]": "at_period_end",
      "features[subscription_update][enabled]": "false",
      "features[customer_update][enabled]": "false",
    }, fetcher);
    db.prepare("INSERT OR REPLACE INTO stripe_objects(key,id) VALUES(?,?)").run(key, c.id);
    return c.id;
  };

  router.post("/checkout", async (req, res) => {
    const brandID = String(req.body?.brand || "");
    const user = await manager(req, res, brandID);
    if (!user) return;
    const existing = current(brandID);
    if (existing && existing.status !== "canceled" && existing.status !== "pending")
      return res.status(409).json({ error: "This brand already has a monthly budget. Change it below." });
    const p = parse(req.body, brandID);
    if (p.error) return res.status(400).json({ error: p.error });
    const id = "bud_" + randomBytes(9).toString("hex");
    const name = brandRecord(brandID)?.name || brandID;
    try {
      // Reuse the brand's Stripe customer from Brand ads (sponsored.js) when it has one.
      let billing = null;
      try { billing = db.prepare("SELECT customer FROM ad_billing WHERE brand_id=?").get(brandID); } catch { /* no brand ads table */ }
      const session = await stripe(env, "POST", "checkout/sessions", {
        mode: "subscription",
        "line_items[0][quantity]": "1",
        "line_items[0][price_data][currency]": "usd",
        "line_items[0][price_data][unit_amount]": String(p.cents),
        "line_items[0][price_data][recurring][interval]": "month",
        "line_items[0][price_data][product]": await budgetProduct(),
        "subscription_data[description]": `${TIERS[p.tier].label} budget for ${name} on Marracat`.slice(0, 250),
        "subscription_data[metadata][budget]": id,
        "subscription_data[metadata][brand]": brandID,
        "metadata[budget]": id,
        "metadata[brand]": brandID,
        "metadata[target]": p.target,
        client_reference_id: id,
        success_url: `${site}/brand-ads?brand=${encodeURIComponent(brandID)}&budget={CHECKOUT_SESSION_ID}`,
        cancel_url: `${site}/brand-ads?brand=${encodeURIComponent(brandID)}`,
        ...(billing?.customer ? { customer: billing.customer } : user.email ? { customer_email: user.email } : {}),
      }, fetcher);
      db.prepare(`INSERT INTO boost_budgets(id,brand_id,user_id,target,tier,monthly_cents,status,session,live,created,updated)
        VALUES(?,?,?,?,?,?,'pending',?,?,?,?)`).run(id, brandID, user.id, p.target, p.tier, p.cents, session.id, session.livemode ? 1 : 0, now(), now());
      res.status(201).json({ url: session.url });
    } catch {
      res.status(502).json({ error: "Checkout couldn't start. Try again." });
    }
  });

  // Back from Checkout: confirm with Stripe directly, before the webhook lands.
  router.get("/session/:id", async (req, res) => {
    const sid = String(req.params.id);
    if (!/^cs_(test|live)_[A-Za-z0-9]+$/.test(sid)) return res.sendStatus(400);
    const plan = db.prepare("SELECT * FROM boost_budgets WHERE session=?").get(sid);
    if (!plan) return res.sendStatus(404);
    if (!(await manager(req, res, plan.brand_id))) return;
    if (plan.status === "pending") {
      try {
        const s = await stripe(env, "GET", `checkout/sessions/${sid}?expand[]=invoice&expand[]=subscription`, null, fetcher);
        if (s.status === "complete") {
          handleBudgetEvent(db, { type: "checkout.session.completed", data: { object: { ...s, subscription: s.subscription?.id || s.subscription } } }, now());
          if (s.invoice?.status === "paid") creditInvoice(db, s.invoice, now());
          if (s.subscription?.id) handleBudgetEvent(db, { type: "customer.subscription.updated", data: { object: s.subscription } }, now());
          allocateBudgets(db, now(), lookup);
        }
      } catch { /* shown as pending until the webhook */ }
    }
    res.json({ plan: view(db.prepare("SELECT * FROM boost_budgets WHERE id=?").get(plan.id)) });
  });

  // New amount or boost from the next month on (no proration).
  router.post("/change", async (req, res) => {
    const brandID = String(req.body?.brand || "");
    if (!(await manager(req, res, brandID))) return;
    const plan = current(brandID);
    if (!plan || !plan.subscription || plan.status === "canceled") return res.status(404).json({ error: "Set up a monthly budget first." });
    const p = parse({ ...req.body, type: plan.target.startsWith("brand:") ? "brand" : "product", id: plan.target.split(":")[1] }, brandID);
    if (p.error) return res.status(400).json({ error: p.error });
    try {
      let item = plan.item;
      if (!item) {
        const sub = await stripe(env, "GET", `subscriptions/${plan.subscription}`, null, fetcher);
        item = sub.items?.data?.[0]?.id;
      }
      if (!item) throw Error("no item");
      await stripe(env, "POST", `subscriptions/${plan.subscription}`, {
        "items[0][id]": item,
        "items[0][price_data][currency]": "usd",
        "items[0][price_data][unit_amount]": String(p.cents),
        "items[0][price_data][recurring][interval]": "month",
        "items[0][price_data][product]": await budgetProduct(),
        proration_behavior: "none",
      }, fetcher);
      db.prepare("UPDATE boost_budgets SET tier=?, monthly_cents=?, item=?, updated=? WHERE id=?").run(p.tier, p.cents, item, now(), plan.id);
      res.json({ plan: view(db.prepare("SELECT * FROM boost_budgets WHERE id=?").get(plan.id)) });
    } catch {
      res.status(502).json({ error: "Stripe didn't answer. Try again." });
    }
  });

  // Stripe's billing page: card, invoices, cancel (at the end of the paid month).
  router.post("/portal", async (req, res) => {
    const brandID = String(req.body?.brand || "");
    if (!(await manager(req, res, brandID))) return;
    const plan = current(brandID);
    if (!plan?.customer) return res.status(404).json({ error: "Set up a monthly budget first." });
    try {
      const s = await stripe(env, "POST", "billing_portal/sessions", {
        customer: plan.customer, return_url: `${site}/brand-ads?brand=${encodeURIComponent(brandID)}`,
        configuration: await portalConfig(),
      }, fetcher);
      res.json({ url: s.url });
    } catch {
      res.status(502).json({ error: "Stripe didn't answer. Try again." });
    }
  });

  router.use((error, req, res, next) => res.status(error.type === "entity.parse.failed" ? 400 : 500).json({ error: "Request could not be completed" }));
  app.use("/api/boost-budgets", router);

  if (schedule) {
    const tick = () => { try { allocateBudgets(db, now(), lookup); } catch (e) { console.error("Boost budgets:", e.message); } };
    setTimeout(tick, 30_000).unref?.();
    setInterval(tick, 10 * 60_000).unref?.();
  }
}
