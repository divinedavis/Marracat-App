import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { setCatalog } from "../server/catalog.js";
import { installBrandClaimSchema } from "../server/brand-claims.js";
import { sponsoredRoutes, pick, tapPrice, recordTap, chargeDue, relevance, liveCampaigns, signImpression, readImpression } from "../server/sponsored.js";

// A verified impression (as /tap reads one) and a distinct IP per tap.
let impN = 0;
const imp = () => ({ n: "imp" + ++impN });
const campaign = (db, brand, products, budget, cpc) =>
  db.prepare("INSERT INTO ad_campaigns(brand_id,created_by,product_ids,daily_budget_cents,max_cpc_cents,status,created,updated,approval) VALUES(?,?,?,?,?,'active',0,0,'approved')")
    .run(brand, "u" + brand, JSON.stringify(products), budget, cpc);

const product = (id, brand, title, category, extra = {}) => ({ id, brand, title, category, price: 20, currency: "USD", available: true, images: [], variants: [], subs: [], tags: [], url: "https://x.com/products/" + id, ...extra });
setCatalog({
  generated_at: "9999-01-01T00:00:00Z", categories: [{ id: "skincare", name: "Skincare", symbol: "s" }, { id: "bags", name: "Bags", symbol: "b" }],
  brands: [{ id: "a", name: "A", domain: "a.com" }, { id: "b", name: "B", domain: "b.com" }],
  products: [product("a1", "a", "Shea Body Butter", "skincare", { subs: ["body"] }), product("a2", "a", "Leather Tote", "bags"),
    product("b1", "b", "Whipped Body Butter", "skincare", { subs: ["body"] }), product("b2", "b", "Lip Oil", "skincare")],
});

function setup() {
  const db = new Database(":memory:");
  installBrandClaimSchema(db);
  db.prepare("INSERT INTO brand_admins VALUES('a','ua','owner','domain-email',0),('b','ub','owner','domain-email',0)").run();
  let clock = Date.UTC(2026, 9, 6, 15);
  const stripeCalls = [];
  const fetcher = async (url, opts) => {
    stripeCalls.push({ url, body: opts?.body ? Object.fromEntries(new URLSearchParams(opts.body)) : null });
    if (url.includes("/customers")) return { ok: true, json: async () => ({ id: "cus_1" }) };
    if (url.includes("/checkout/sessions/cs_test_x")) return { ok: true, json: async () => ({ metadata: { brand: "a" }, customer: "cus_1", setup_intent: { payment_method: { id: "pm_1", card: { brand: "visa", last4: "4242" } } } }) };
    if (url.includes("/checkout/sessions")) return { ok: true, json: async () => ({ url: "https://checkout.stripe.com/c/pay/x" }) };
    if (url.includes("/payment_intents")) return { ok: true, json: async () => ({ id: "pi_1", status: "succeeded" }) };
    return { ok: false, json: async () => ({ error: { message: "?" } }) };
  };
  const app = express();
  const users = { ua: { id: "ua", email: "x@a.com" }, ub: { id: "ub", email: "x@b.com" }, owner: { id: "o", email: "divinejdavis@gmail.com" }, shopper: { id: "s", email: "s@example.com" } };
  sponsoredRoutes(app, db, { env: { STRIPE_SECRET_KEY: "sk_test_1", ADS_IMPRESSION_KEY: "k" }, viewer: async (req) => users[req.get("X-User")] || null, fetcher, now: () => clock, schedule: false });
  return { db, app, stripeCalls, fetcher, tick: (ms) => (clock += ms), now: () => clock };
}
async function serve(app) {
  const s = app.listen(0); await new Promise((r) => s.once("listening", r));
  const base = `http://127.0.0.1:${s.address().port}/api/ads`;
  const call = async (method, path, body, user, device = "dev1") => {
    const r = await fetch(base + path, { method, headers: { "Content-Type": "application/json", "X-Marracat-Device": device, ...(user ? { "X-User": user } : {}) }, body: body && JSON.stringify(body) });
    return { status: r.status, body: r.status === 204 ? null : await r.json().catch(() => null) };
  };
  return { call, close: () => s.close() };
}

test("only a verified brand runs ads, and only for its own products", async () => {
  const t = setup(); const { call, close } = await serve(t.app);
  try {
    assert.equal((await call("PUT", "/campaign", { brand: "a", productIDs: ["a1"], dailyBudget: 10, maxCPC: 0.5 })).status, 401);
    assert.equal((await call("PUT", "/campaign", { brand: "a", productIDs: ["a1"], dailyBudget: 10, maxCPC: 0.5 }, "ub")).status, 403, "another brand's admin");
    assert.equal((await call("PUT", "/campaign", { brand: "a", productIDs: ["b1"], dailyBudget: 10, maxCPC: 0.5 }, "ua")).status, 400, "someone else's product");
    assert.equal((await call("PUT", "/campaign", { brand: "a", productIDs: ["a1"], dailyBudget: 2, maxCPC: 0.5 }, "ua")).status, 400, "budget under $5");
    const ok = await call("PUT", "/campaign", { brand: "a", productIDs: ["a1", "a2"], dailyBudget: 10, maxCPC: 0.5 }, "ua");
    assert.equal(ok.status, 200);
    assert.deepEqual(ok.body.campaign, { productIDs: ["a1", "a2"], dailyBudget: 10, maxCPC: 0.5, status: "active", approval: "pending" });
    assert.equal(ok.body.card, null, "no card yet, so nothing shows");
    assert.equal((await call("GET", "/brands", null, "ua")).body.brands[0].brand.id, "a");
  } finally { close(); }
});

test("a card is saved through Stripe setup, then ads serve where they fit (owner only in test mode)", async () => {
  const t = setup(); const { call, close } = await serve(t.app);
  try {
    await call("PUT", "/campaign", { brand: "a", productIDs: ["a1", "a2"], dailyBudget: 10, maxCPC: 0.5 }, "ua");
    const setupRes = await call("POST", "/billing/setup", { brand: "a" }, "ua");
    assert.equal(setupRes.status, 201);
    assert.equal(t.stripeCalls.find((c) => c.url.endsWith("/checkout/sessions")).body.mode, "setup");
    const confirmed = await call("POST", "/billing/confirm", { brand: "a", session: "cs_test_x" }, "ua");
    assert.equal(confirmed.body.card, "visa ending 4242");
    assert.deepEqual((await call("GET", "/serve?placement=search&q=body+butter", null, "owner")).body.items, [], "not before the owner approves");
    assert.equal((await call("POST", "/admin/approve", { brand: "a", approve: true }, "ua")).status, 403, "only the owner approves");
    assert.equal((await call("POST", "/admin/approve", { brand: "a", approve: true }, "owner")).body.campaign.approval, "approved");
    assert.deepEqual((await call("GET", "/serve?placement=search&q=body+butter", null, "shopper")).body.items, [], "test mode: not for the public");
    const ids = (r) => r.body.items.map(({ brandID, productID }) => ({ brandID, productID }));
    const s = await call("GET", "/serve?placement=search&q=body+butter", null, "owner");
    assert.deepEqual(ids(s), [{ brandID: "a", productID: "a1" }]);
    assert.match(s.body.items[0].impression, /^[\w-]+\.[\w-]+$/, "each item carries a signed impression id");
    assert.deepEqual(ids(await call("GET", "/serve?placement=search&q=lip+gloss", null, "owner")), [], "nothing that doesn't fit");
    assert.deepEqual(ids(await call("GET", "/serve?placement=category&category=bags", null, "owner")), [{ brandID: "a", productID: "a2" }]);
    // Changing the products sends it back for approval; a budget change doesn't.
    await call("PUT", "/campaign", { brand: "a", productIDs: ["a1", "a2"], dailyBudget: 20, maxCPC: 0.5 }, "ua");
    assert.equal(ids(await call("GET", "/serve?placement=category&category=bags", null, "owner")).length, 1);
    const changed = await call("PUT", "/campaign", { brand: "a", productIDs: ["a2"], dailyBudget: 20, maxCPC: 0.5 }, "ua");
    assert.equal(changed.body.campaign.approval, "pending");
    assert.deepEqual(ids(await call("GET", "/serve?placement=category&category=bags", null, "owner")), []);
  } finally { close(); }
});

test("a tap costs a cent over the next bid, at least 20 cents, never over the cap", () => {
  assert.equal(tapPrice({ max_cpc_cents: 100 }, []), 20);
  assert.equal(tapPrice({ max_cpc_cents: 100 }, [{ max_cpc_cents: 60 }]), 61);
  assert.equal(tapPrice({ max_cpc_cents: 50 }, [{ max_cpc_cents: 80 }]), 20, "a higher bid elsewhere isn't this brand's price");
  const ranked = pick([{ brand_id: "a", max_cpc_cents: 30, products: ["a1"] }, { brand_id: "b", max_cpc_cents: 90, products: ["b1"] }],
    { placement: "search", q: "body butter" }, 2);
  assert.deepEqual(ranked.map((r) => r.brandID), ["b", "a"], "the higher bid leads");
  assert.equal(relevance({ id: "b1", brand: "b", category: "skincare", available: true, subs: ["body"] }, { placement: "product", near: { id: "a1", brand: "a", category: "skincare", subs: ["body"] } }), 1);
});

test("fair taps: once per phone per product per day, never the brand's own, never past the budget", () => {
  const t = setup();
  campaign(t.db, "a", ["a1"], 500, 200);
  t.db.prepare("INSERT INTO ad_billing(brand_id,customer,payment_method,updated) VALUES('a','cus','pm',0)").run();
  const tap = (viewer, userID) => recordTap(t.db, { brandID: "a", productID: "a1", placement: "search", viewer, userID, now: t.now(), impression: imp(), ip: "ip-" + viewer });
  assert.equal(tap("v1"), 20);
  assert.equal(tap("v1"), 0, "same phone, same product, same day");
  assert.equal(tap("v2", "ua"), 0, "the brand's own people");
  for (let i = 3; i < 30; i++) tap("v" + i);
  assert.ok(t.db.prepare("SELECT SUM(cost_cents) AS c FROM ad_events").get().c <= 500, "never past the $5 day");
  assert.equal(liveCampaigns(t.db, t.now()).length, 0, "out of budget: stops showing");
  t.tick(86400_000);
  assert.equal(liveCampaigns(t.db, t.now()).length, 1, "back the next day");
});

test("brands are charged once $25 is owed; a failed charge pauses their ads", async () => {
  const t = setup();
  campaign(t.db, "a", ["a1"], 50000, 500);
  t.db.prepare("INSERT INTO ad_billing(brand_id,customer,payment_method,updated) VALUES('a','cus','pm',?)").run(t.now());
  for (let i = 0; i < 4; i++) recordTap(t.db, { brandID: "a", productID: "a1", viewer: "v" + i, now: t.now(), impression: imp(), ip: "ip" + i });
  assert.equal(await chargeDue(t.db, { env: { STRIPE_SECRET_KEY: "sk_test" }, fetcher: t.fetcher, now: t.now, log: () => {} }), 0, "$0.80 owed: not yet");
  t.db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,viewer,cost_cents,day,created) VALUES('a','a1','tap','x',2500,'2026-10-06',0)").run();
  assert.equal(await chargeDue(t.db, { env: { STRIPE_SECRET_KEY: "sk_test" }, fetcher: t.fetcher, now: t.now, log: () => {} }), 1);
  const pi = t.stripeCalls.find((c) => c.url.includes("payment_intents")).body;
  assert.equal(pi.amount, "2580"); assert.equal(pi.off_session, "true");
  assert.equal(t.db.prepare("SELECT COUNT(*) AS n FROM ad_events WHERE billed IS NULL AND cost_cents>0").get().n, 0);
  const failing = async () => ({ ok: false, json: async () => ({ error: { message: "card declined" } }) });
  t.db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,viewer,cost_cents,day,created) VALUES('a','a1','tap','y',3000,'2026-10-06',0)").run();
  await chargeDue(t.db, { env: { STRIPE_SECRET_KEY: "sk_test" }, fetcher: failing, now: t.now, log: () => {} });
  assert.equal(liveCampaigns(t.db, t.now()).length, 0, "paused until a new card");
});

// Audit 2026-10-07 (M5): taps are charged only with a signed, single-use
// impression from /serve, and at most 10 a day per IP.
test("impression ids are signed, bound to the product and expire", () => {
  const tok = signImpression("k", { brandID: "a", productID: "a1", placement: "search", now: 1000 });
  assert.ok(readImpression("k", tok, { brandID: "a", productID: "a1", now: 2000 }));
  assert.equal(readImpression("other", tok, { brandID: "a", productID: "a1", now: 2000 }), null, "wrong key");
  assert.equal(readImpression("k", tok, { brandID: "a", productID: "a2", now: 2000 }), null, "another product");
  assert.equal(readImpression("k", tok, { brandID: "a", productID: "a1", now: 1000 + 31 * 60_000 }), null, "expired");
  assert.equal(readImpression("k", tok.slice(0, -2) + "xx", { brandID: "a", productID: "a1", now: 2000 }), null, "tampered");
  assert.equal(readImpression("k", undefined, { brandID: "a", productID: "a1", now: 2000 }), null);
});

test("no impression, a reused one, or too many from one IP: recorded, never charged", () => {
  const t = setup();
  campaign(t.db, "a", ["a1", "a2"], 50000, 200);
  t.db.prepare("INSERT INTO ad_billing(brand_id,customer,payment_method,updated) VALUES('a','cus','pm',0)").run();
  const tap = (o) => recordTap(t.db, { brandID: "a", productID: "a1", viewer: "v" + Math.random(), now: t.now(), ...o });
  assert.equal(tap({ ip: "ip1" }), 0, "no impression (old app builds)");
  const once = imp();
  assert.equal(tap({ impression: once, ip: "ip2" }), 20);
  assert.equal(tap({ impression: once, ip: "ip3", productID: "a2" }), 0, "an impression is single use");
  assert.equal(tap({ impression: imp(), ip: "ip2" }), 0, "same IP, same product, same day");
  for (let i = 0; i < 12; i++) recordTap(t.db, { brandID: "a", productID: i % 2 ? "a1" : "a2", viewer: "w" + i, now: t.now() + i, impression: imp(), ip: "ip9" });
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM ad_events WHERE ip='ip9' AND cost_cents>0").get().n, 2, "one per product per IP per day");
  // Ten charged taps from one IP today (any brand): the eleventh is free.
  for (let i = 0; i < 10; i++)
    t.db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,viewer,cost_cents,day,created,ip) VALUES('b','b1','tap',?,20,'2026-10-06',?,'ipX')").run("x" + i, t.now() - 1000);
  assert.equal(tap({ impression: imp(), ip: "ipX" }), 0, "10 charged taps per IP per day");
  assert.equal(tap({ impression: imp(), ip: "ipY" }), 20, "another IP still counts");
});

test("an old app's tap (no impression) still gets 204 over HTTP", async () => {
  const t = setup(); const { call, close } = await serve(t.app);
  try {
    campaign(t.db, "a", ["a1"], 50000, 200);
    t.db.prepare("INSERT INTO ad_billing(brand_id,customer,payment_method,updated) VALUES('a','cus','pm',0)").run();
    assert.equal((await call("POST", "/tap", { brandID: "a", productID: "a1", placement: "search" })).status, 204);
    // The phone that was shown the ad taps it and is charged; the same
    // impression from another phone is recorded, not charged (2026-11-12).
    const served = await call("GET", "/serve?placement=search&q=body+butter", null, "owner", "dev2");
    const item = served.body.items[0];
    assert.equal((await call("POST", "/tap", { ...item, placement: "search" }, null, "dev3")).status, 204);
    assert.equal((await call("POST", "/tap", { ...item, placement: "search" }, null, "dev2")).status, 204);
    assert.deepEqual(t.db.prepare("SELECT cost_cents FROM ad_events WHERE kind='tap' ORDER BY id").all().map((r) => r.cost_cents), [0, 0, 20]);
  } finally { close(); }
});

// 2026-11-12: a charge carried no idempotency key, so a payment Stripe took
// but never answered for was charged again; and an impression collected
// under one identity could be spent under another.
test("a charge that got no answer is retried with the same key, never charged twice or counted as a bad card", async () => {
  const t = setup();
  campaign(t.db, "a", ["a1"], 50000, 500);
  t.db.prepare("INSERT INTO ad_billing(brand_id,customer,payment_method,updated) VALUES('a','cus','pm',?)").run(t.now());
  t.db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,viewer,cost_cents,day,created) VALUES('a','a1','tap','x',2600,'2026-10-06',0)").run();
  const keys = [];
  const timeout = async (url, opts) => { keys.push(opts.headers["Idempotency-Key"]); throw Object.assign(new Error("timed out"), { name: "TimeoutError" }); };
  const env = { STRIPE_SECRET_KEY: "sk_test" };
  assert.equal(await chargeDue(t.db, { env, fetcher: timeout, now: t.now, log: () => {} }), 0);
  assert.equal(t.db.prepare("SELECT failed FROM ad_billing WHERE brand_id='a'").get().failed, null, "the card isn't blamed");
  assert.equal(t.db.prepare("SELECT COUNT(*) AS n FROM ad_charges").get().n, 0);
  assert.equal(liveCampaigns(t.db, t.now()).length, 1, "ads keep running");
  const answer = async (url, opts) => { keys.push(opts.headers["Idempotency-Key"]); return { ok: true, json: async () => ({ id: "pi_1", status: "succeeded" }) }; };
  assert.equal(await chargeDue(t.db, { env, fetcher: answer, now: t.now, log: () => {} }), 1);
  assert.match(keys[0], /^[a-f0-9]{64}$/);
  assert.equal(keys[1], keys[0], "the retry is the same payment to Stripe");
  t.db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,viewer,cost_cents,day,created) VALUES('a','a1','tap','y',2600,'2026-10-07',0)").run();
  await chargeDue(t.db, { env, fetcher: answer, now: t.now, log: () => {} });
  assert.notEqual(keys[2], keys[0], "new taps are a new payment");
});

test("two charge runs at once: the second stands down", async () => {
  const t = setup();
  campaign(t.db, "a", ["a1"], 50000, 500);
  t.db.prepare("INSERT INTO ad_billing(brand_id,customer,payment_method,updated) VALUES('a','cus','pm',?)").run(t.now());
  t.db.prepare("INSERT INTO ad_events(brand_id,product_id,kind,viewer,cost_cents,day,created) VALUES('a','a1','tap','x',2600,'2026-10-06',0)").run();
  let calls = 0, release;
  const slow = async () => { calls++; await new Promise((r) => (release = r)); return { ok: true, json: async () => ({ id: "pi_1", status: "succeeded" }) }; };
  const env = { STRIPE_SECRET_KEY: "sk_test" };
  const first = chargeDue(t.db, { env, fetcher: slow, now: t.now, log: () => {} });
  await new Promise((r) => setImmediate(r));
  assert.equal(await chargeDue(t.db, { env, fetcher: slow, now: t.now, log: () => {} }), 0);
  release();
  assert.equal(await first, 1);
  assert.equal(calls, 1);
});

test("an impression is good only for the viewer it was shown to", () => {
  const tok = signImpression("k", { brandID: "a", productID: "a1", placement: "search", now: 1000, viewer: "viewer-one" });
  assert.ok(readImpression("k", tok, { brandID: "a", productID: "a1", now: 2000, viewer: "viewer-one" }));
  assert.equal(readImpression("k", tok, { brandID: "a", productID: "a1", now: 2000, viewer: "viewer-two" }), null);
  const unbound = signImpression("k", { brandID: "a", productID: "a1", placement: "search", now: 1000 });
  assert.equal(readImpression("k", unbound, { brandID: "a", productID: "a1", now: 2000, viewer: "viewer-one" }), null, "one issued without a viewer isn't charged");
});
