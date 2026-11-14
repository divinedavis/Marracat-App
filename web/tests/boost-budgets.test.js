import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { createHmac } from "node:crypto";
import { setCatalog } from "../server/catalog.js";
import { installBrandClaimSchema } from "../server/brand-claims.js";
import { boostRoutes, activeBoosts } from "../server/boosts.js";
import { budgetRoutes, allocateBudgets, balance, monthlyCap, allowedTiers, handleBudgetEvent, installBudgetSchema } from "../server/boost-budgets.js";

// Monthly boost budgets (owner, 2026-10-10): verified brands only, amounts
// from the server, each paid invoice credited once, spend never past paid.
const product = (id, brand) => ({ id, brand, title: id, category: "skincare", price: 20, currency: "USD", available: true, images: ["https://x/i.jpg"], variants: [], subs: [], tags: [], url: "https://x.com/products/" + id });
setCatalog({
  generated_at: "9999-01-01T00:00:00Z", categories: [{ id: "skincare", name: "Skincare", symbol: "s" }],
  brands: [{ id: "a", name: "A", domain: "a.com" }, { id: "b", name: "B", domain: "b.com" }],
  products: [product("a1", "a"), product("b1", "b")],
});
const DAY = 86400e3;
const SECRET = "whsec_test";

function setup({ key = "sk_live_1" } = {}) {
  const db = new Database(":memory:");
  installBrandClaimSchema(db);
  db.prepare("INSERT INTO brand_admins VALUES('a','ua','owner','domain-email',0),('b','ub','owner','domain-email',0)").run();
  let clock = Date.UTC(2026, 9, 10, 15);
  const calls = [];
  const fetcher = async (url, opts) => {
    const body = opts?.body ? Object.fromEntries(new URLSearchParams(opts.body)) : null;
    calls.push({ url, method: opts?.method, body });
    const ok = (o) => ({ ok: true, json: async () => o });
    if (url.endsWith("/products")) return ok({ id: "prod_1" });
    if (url.endsWith("/checkout/sessions")) return ok({ id: "cs_live_" + calls.length, url: "https://checkout.stripe.com/c/pay/x", livemode: key.startsWith("sk_live_") });
    if (url.includes("/subscriptions/sub_1")) return ok({ id: "sub_1", items: { data: [{ id: "si_1" }] } });
    if (url.endsWith("/billing_portal/sessions")) return ok({ url: "https://billing.stripe.com/p/session/x" });
    if (url.endsWith("/billing_portal/configurations")) return ok({ id: "bpc_1" });
    return { ok: false, json: async () => ({ error: { message: "?" } }) };
  };
  const users = { ua: { id: "ua", email: "x@a.com" }, ub: { id: "ub", email: "x@b.com" }, owner: { id: "o", email: "divinejdavis@gmail.com" }, shopper: { id: "s", email: "s@example.com" } };
  const env = { STRIPE_SECRET_KEY: key, STRIPE_WEBHOOK_SECRET: SECRET };
  const app = express();
  const viewer = async (req) => users[req.get("X-User")] || null;
  boostRoutes(app, db, { env, viewer, fetcher, now: () => clock });
  budgetRoutes(app, db, { env, viewer, fetcher, now: () => clock, schedule: false });
  return { db, app, calls, tick: (ms) => (clock += ms), now: () => clock };
}
async function serve(app) {
  const s = app.listen(0); await new Promise((r) => s.once("listening", r));
  const base = `http://127.0.0.1:${s.address().port}`;
  const call = async (method, path, body, user) => {
    const r = await fetch(base + path, { method, headers: { "Content-Type": "application/json", ...(user ? { "X-User": user } : {}) }, body: body && JSON.stringify(body) });
    return { status: r.status, body: await r.json().catch(() => null) };
  };
  const hook = async (event, now, secret = SECRET) => {
    const raw = JSON.stringify(event), t = Math.floor(now / 1000);
    const sig = createHmac("sha256", secret).update(`${t}.${raw}`).digest("hex");
    return (await fetch(base + "/api/stripe/webhook", { method: "POST", headers: { "Content-Type": "application/json", "Stripe-Signature": `t=${t},v1=${sig}` }, body: raw })).status;
  };
  return { call, hook, close: () => s.close() };
}
const invoice = (id, cents, budget, now) => ({ id: "evt_" + id, type: "invoice.paid", data: { object: {
  id, amount_paid: cents, parent: { subscription_details: { subscription: "sub_1", metadata: { budget } } },
  lines: { data: [{ period: { start: Math.floor(now / 1000), end: Math.floor((now + 30 * DAY) / 1000) } }] } } } });

test("monthly ranges: a boost's own price up to running it back-to-back for 31 days", () => {
  assert.equal(monthlyCap(100), 500);
  assert.equal(monthlyCap(5), 155);
  assert.equal(monthlyCap(20), 220);
  assert.deepEqual(allowedTiers(100), [100, 50, 20, 5]);
  assert.deepEqual(allowedTiers(20), [20], "Boost (picks only) never buys a lift-only Spark");
});

test("only the brand's verified admin can start one, with server-side amounts", async () => {
  const t = setup();
  const s = await serve(t.app);
  try {
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 400 })).status, 401);
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 400 }, "shopper")).status, 403);
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 400 }, "ub")).status, 403, "another brand's admin");
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "product", id: "b1", tier: 100, dollars: 400 }, "ua")).status, 400, "someone else's product");
    for (const dollars of [99, 501, 150.5, "abc", -5, null]) {
      assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars }, "ua")).status, 400, `dollars ${dollars}`);
    }
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 7, dollars: 100 }, "ua")).status, 400);
    const ok = await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "product", id: "a1", tier: 50, dollars: 200, unit_amount: 1 }, "ua");
    assert.equal(ok.status, 201);
    const session = t.calls.find((c) => c.url.endsWith("/checkout/sessions")).body;
    assert.equal(session.mode, "subscription");
    assert.equal(session["line_items[0][price_data][unit_amount]"], "20000");
    assert.equal(session["line_items[0][price_data][recurring][interval]"], "month");
    assert.match(session["subscription_data[metadata][budget]"], /^bud_/);
    assert.equal(session["metadata[target]"], "product:a1");
    // One plan per brand.
    t.db.prepare("UPDATE boost_budgets SET status='active'").run();
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 400 }, "ua")).status, 409);
  } finally { s.close(); }
});

test("test mode: only the owner, and its boosts never show publicly", async () => {
  const t = setup({ key: "sk_test_1" });
  const s = await serve(t.app);
  try {
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 400 }, "ua")).status, 503);
    assert.equal((await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 400 }, "owner")).status, 201);
    const plan = t.db.prepare("SELECT * FROM boost_budgets").get();
    assert.equal(plan.live, 0);
    assert.equal(await s.hook(invoice("in_t", 40000, plan.id, t.now()), t.now()), 200);
    assert.equal(t.db.prepare("SELECT COUNT(*) n FROM boosts WHERE budget_id=?").get(plan.id).n, 1);
    assert.deepEqual(activeBoosts(t.db, t.now() + 1000).premier, [], "a test-mode plan's boost isn't public");
  } finally { s.close(); }
});

test("a paid month is credited once, and spend never passes what was paid", async () => {
  const t = setup();
  const s = await serve(t.app);
  try {
    await s.call("POST", "/api/boost-budgets/checkout", { brand: "a", type: "brand", id: "a", tier: 100, dollars: 230 }, "ua");
    const plan = t.db.prepare("SELECT * FROM boost_budgets").get();
    const sid = plan.session;
    assert.equal(await s.hook({ id: "evt_cs", type: "checkout.session.completed", data: { object: { id: sid, mode: "subscription", subscription: "sub_1", customer: "cus_9" } } }, t.now()), 200);
    // A forged signature changes nothing.
    assert.equal(await s.hook(invoice("in_fake", 9_999_900, plan.id, t.now()), t.now(), "whsec_wrong"), 400);
    const ev = invoice("in_1", 23000, plan.id, t.now());
    assert.equal(await s.hook(ev, t.now()), 200);
    assert.equal(await s.hook(ev, t.now()), 200, "a retried event is acknowledged");
    assert.equal(await s.hook({ ...ev, id: "evt_other" }, t.now()), 200, "the same invoice under a new event id");
    assert.equal(balance(t.db, plan.id).paid, 23000, "credited once");
    // $230 on Spotlight: two Spotlights, then the $30 left buys a Boost and two Sparks.
    for (let i = 0; i < 40; i++) { allocateBudgets(t.db, t.now()); t.tick(DAY); }
    const runs = t.db.prepare("SELECT tier, starts, ends FROM boosts WHERE budget_id=? ORDER BY starts").all(plan.id);
    assert.deepEqual(runs.map((r) => r.tier), [100, 100, 20, 5, 5]);
    assert.equal(balance(t.db, plan.id).spent, 23000);
    assert.ok(balance(t.db, plan.id).left >= 0);
    for (let i = 1; i < runs.length; i++) assert.ok(runs[i].starts >= runs[i - 1].ends, "one at a time, back-to-back");
    const view = await s.call("GET", "/api/boost-budgets?brand=a", null, "ua");
    assert.equal(view.body.plan.paid, 230);
    assert.equal(view.body.plan.status, "active");
    assert.equal((await s.call("GET", "/api/boost-budgets?brand=a", null, "ub")).status, 403);
  } finally { s.close(); }
});

test("a failed payment pauses spending; a cancellation spends what was paid, then stops", () => {
  const t = setup();
  installBudgetSchema(t.db);
  const add = (id, status) => t.db.prepare("INSERT INTO boost_budgets(id,brand_id,user_id,target,tier,monthly_cents,status,subscription,live,created,updated) VALUES(?,?,?,?,?,?,?,?,1,0,0)")
    .run(id, "a", "ua", "brand:a", 100, 20000, status, "sub_" + id);
  add("p1", "active");
  t.db.prepare("INSERT INTO boost_budget_credits VALUES('in_a','p1',20000,0,0,0)").run();
  handleBudgetEvent(t.db, { type: "invoice.payment_failed", data: { object: { id: "in_b", parent: { subscription_details: { subscription: "sub_p1" } } } } }, t.now());
  assert.equal(t.db.prepare("SELECT status FROM boost_budgets WHERE id='p1'").get().status, "past_due");
  assert.deepEqual(allocateBudgets(t.db, t.now()), [], "nothing runs while a payment is failing");
  handleBudgetEvent(t.db, { type: "customer.subscription.deleted", data: { object: { id: "sub_p1", status: "canceled" } } }, t.now());
  assert.equal(t.db.prepare("SELECT status FROM boost_budgets WHERE id='p1'").get().status, "canceled");
  assert.equal(allocateBudgets(t.db, t.now()).length, 1, "paid money still runs after cancelling");
  t.tick(8 * DAY);
  allocateBudgets(t.db, t.now());
  t.tick(8 * DAY);
  assert.deepEqual(allocateBudgets(t.db, t.now()), [], "and stops once it's spent");
  assert.equal(balance(t.db, "p1").left, 0);
});

test("change and cancel go through Stripe for the brand's own plan only", async () => {
  const t = setup();
  const s = await serve(t.app);
  try {
    t.db.prepare("INSERT INTO boost_budgets(id,brand_id,user_id,target,tier,monthly_cents,status,subscription,customer,live,created,updated) VALUES('p','a','ua','brand:a',100,40000,'active','sub_1','cus_1',1,0,0)").run();
    assert.equal((await s.call("POST", "/api/boost-budgets/change", { brand: "a", tier: 100, dollars: 9000 }, "ua")).status, 400);
    const r = await s.call("POST", "/api/boost-budgets/change", { brand: "a", tier: 50, dollars: 150 }, "ua");
    assert.equal(r.status, 200);
    const upd = t.calls.find((c) => c.url.endsWith("/subscriptions/sub_1") && c.method === "POST").body;
    assert.equal(upd["items[0][price_data][unit_amount]"], "15000");
    assert.equal(upd.proration_behavior, "none");
    assert.equal(r.body.plan.monthly, 150);
    assert.equal((await s.call("POST", "/api/boost-budgets/portal", { brand: "a" }, "ub")).status, 403);
    const portal = await s.call("POST", "/api/boost-budgets/portal", { brand: "a" }, "ua");
    assert.match(portal.body.url, /^https:\/\/billing\.stripe\.com\//);
    const cfg = t.calls.find((c) => c.url.endsWith("/billing_portal/configurations")).body;
    assert.equal(cfg["features[subscription_cancel][mode]"], "at_period_end");
    assert.equal(t.calls.find((c) => c.url.endsWith("/billing_portal/sessions")).body.configuration, "bpc_1");
    await s.call("POST", "/api/boost-budgets/portal", { brand: "a" }, "ua");
    assert.equal(t.calls.filter((c) => c.url.endsWith("/billing_portal/configurations")).length, 1, "the portal settings are made once");
  } finally { s.close(); }
});
