import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { carrierLink, trackingRoutes, checkTrackedOrders, parseStatusPage, allowedPage, ucpEndpointFor, diagnose, track17Update, easyPostUpdate, installTrackingSchema, itemPhrase, pushText, brandNameFor } from "../server/order-tracking.js";
import { trackerBudget } from "../server/relay.js";

const brands = {
  honey: { id: "honey", name: "The Honey Pot", domain: "thehoneypot.co", ucp: "https://honey.myshopify.com/api/ucp/mcp" },
  noucp: { id: "noucp", name: "Plain", domain: "plain.com" },
  ripl: { id: "ripl", name: "RIPL EFEK", domain: "riplefek.com", shopify: true },
  evil: { id: "evil", name: "Evil", domain: "evil.com", ucp: "https://169.254.169.254/api/ucp/mcp" },
};
const lookup = (id) => brands[id];
const key = (c) => c.repeat(64);
const CHECKOUT = "gid://shopify/Checkout/TESTcheckout0000000000AB?key=00112233445566778899aabbccddeeff";
const PERMALINK = "https://thehoneypot.co/12345678/orders/0123456789abcdef0123456789abcdef/authenticate?key=fedcba9876543210fedcba9876543210";

// Shopify's server-rendered order status page, trimmed to what matters.
const shippedPage = `<!doctype html><html><head><title>Order #1042 - The Honey Pot</title></head><body>
  <h2>Order #1042</h2><ol class="timeline"><li>Confirmed</li><li class="os-step current">On its way</li><li>Out for delivery</li><li>Delivered</li></ol>
  <p>Your shipment is on its way. USPS tracking number: <a href="https://tools.usps.com/go/TrackConfirmAction?tLabels=9400111899223197428490">9400111899223197428490</a></p>
</body></html>`;
const deliveredJSON = `<html><body><div id="app"></div><script type="application/json">{"fulfillments":[{"displayFulfillmentStatus":"DELIVERED","trackingInfo":[{"number":"1Z999AA10123456784","url":"https://www.ups.com/track?tracknum=1Z999AA10123456784"}]}]}</script></body></html>`;
const shell = `<html><head><script src="/checkouts/app.js"></script><script>window.__boot={}</script></head><body><div id="root"></div></body></html>`;
const wall = `<html><body><h1>Log in to view your order</h1><p>We sent a verification code to your email.</p></body></html>`;

async function fixture(t, { fetcher = fetch, apns = { configured: () => true, send: async () => ({ status: 200 }) }, tracker = null } = {}) {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE restock_devices (hash TEXT PRIMARY KEY, token TEXT, environment TEXT, updated INTEGER NOT NULL)");
  const app = express();
  trackingRoutes(app, db, { apns, lookup, fetcher, schedule: false, tracker });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => { server.close(); db.close(); });
  const base = `http://127.0.0.1:${server.address().port}/api/orders/tracked`;
  const call = async (device, body, method = body ? "POST" : "GET", path = "") => {
    const r = await fetch(base + path, { method, headers: { "Content-Type": "application/json", ...(device ? { "X-Marracat-Device": device } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: r.status, data: await r.json() };
  };
  return { db, call };
}

test("only https links on the brand's domain, a myshopify store or shopify.com are fetched", () => {
  const b = brands.honey;
  assert.ok(allowedPage(PERMALINK, b));
  assert.ok(allowedPage("https://www.thehoneypot.co/orders/1", b));
  assert.ok(allowedPage("https://honey.myshopify.com/1/orders/x", b));
  assert.ok(allowedPage("https://shopify.com/12345/account/orders/9", b));
  for (const bad of ["http://thehoneypot.co/x", "https://evil.com/x", "https://thehoneypot.co.evil.com/x", "https://user:pw@thehoneypot.co/x",
    "https://thehoneypot.co:8443/x", "https://169.254.169.254/latest", "https://localhost/x", "file:///etc/passwd", "not a url"])
    assert.equal(allowedPage(bad, b), null, bad);
  assert.equal(ucpEndpointFor("honey", lookup).hostname, "honey.myshopify.com");
  assert.equal(ucpEndpointFor("noucp", lookup), null);
  assert.equal(ucpEndpointFor("evil", lookup), null, "a catalog UCP endpoint off Shopify and off the brand's domain is refused");
});

test("the status page reads in server-rendered and embedded-JSON forms; a shell or a wall reads as nothing", () => {
  const shipped = parseStatusPage(shippedPage);
  assert.equal(shipped.state, "shipped");
  assert.equal(shipped.carrier, "USPS");
  assert.equal(shipped.trackingNumber, "9400111899223197428490");
  assert.match(shipped.trackingURL, /usps\.com/);
  assert.equal(shipped.orderName, "#1042");
  const delivered = parseStatusPage(deliveredJSON);
  assert.equal(delivered.state, "delivered");
  assert.equal(delivered.trackingNumber, "1Z999AA10123456784");
  assert.equal(parseStatusPage(shell), null);
  assert.equal(parseStatusPage(wall), null);
  assert.equal(parseStatusPage(`<p>Your order is out for delivery</p>`).state, "out_for_delivery");
});

test("the diagnosis names the page kind without tokens", () => {
  const d1 = diagnose({ status: 200, finalURL: PERMALINK, type: "text/html", bytes: 10, parsed: null, html: shell });
  assert.match(d1, /js-shell/);
  assert.doesNotMatch(d1, /0123456789abcdef0123456789abcdef|fedcba9876543210/);
  assert.match(diagnose({ status: 200, finalURL: "https://shopify.com/authentication/1/login", type: "text/html", bytes: 10, parsed: null, html: wall }), /wall/);
  assert.match(diagnose({ status: 200, finalURL: PERMALINK, type: "text/html", bytes: 10, parsed: { state: "shipped", trackingNumber: "x" } }), /read:shipped\+tracking/);
});

test("registering needs a device key, a trackable brand and a real checkout id; devices see only their own", async (t) => {
  const { call } = await fixture(t);
  const a = key("a"), b = key("b");
  assert.equal((await call(null)).status, 401);
  assert.equal((await call(a, { brandID: "noucp", checkoutID: CHECKOUT })).status, 422, "not a Shopify brand");
  assert.equal((await call(a, { brandID: "nobody", orderID: "gid://shopify/OrderIdentity/1" })).status, 422, "not in the catalog");
  assert.equal((await call(a, { brandID: "ripl" })).status, 400, "neither a checkout nor an order");
  assert.equal((await call(a, { brandID: "honey", checkoutID: "https://evil.com" })).status, 400);
  assert.equal((await call(a, { brandID: "honey", checkoutID: CHECKOUT, orderID: "drop table" })).status, 400);
  const ok = await call(a, { brandID: "honey", checkoutID: CHECKOUT, orderID: "gid://shopify/OrderIdentity/18920612135005" });
  assert.equal(ok.status, 201);
  assert.equal(ok.data.orders.length, 1);
  assert.equal(ok.data.orders[0].checkoutID, CHECKOUT.split("?")[0], "the checkout key is never echoed");
  assert.equal((await call(a, { brandID: "honey", checkoutID: CHECKOUT })).data.orders.length, 1, "the same checkout registers once");
  assert.equal((await call(a, { brandID: "honey", orderID: "gid://shopify/Order/18920612135005" })).data.orders.length, 1,
    "an order already followed by its checkout isn't added again by its order id");
  assert.equal((await call(b)).data.orders.length, 0);
  assert.equal((await call(a, null, "DELETE")).data.orders.length, 0);
});

test("the job resolves the status page, follows it to shipped, pushes once, and refuses redirects off-site", async (t) => {
  const calls = [];
  let page = shippedPage, redirect = null;
  const fetcher = async (url, opts) => {
    const u = String(url);
    calls.push(u);
    if (u.includes("/api/ucp/mcp")) {
      const id = JSON.parse(opts.body).params.arguments.id;
      assert.equal(id, CHECKOUT);
      return new Response(JSON.stringify({ result: { structuredContent: { id, status: "completed",
        order: { id: "gid://shopify/Order/18920612135005", permalink_url: PERMALINK } } } }), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (redirect) return new Response("", { status: 302, headers: { location: redirect } });
    return new Response(page, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } });
  };
  const pushes = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const { db, call } = await fixture(t, { fetcher, apns });
  const a = key("a");
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run((await import("node:crypto")).createHash("sha256").update(a).digest("hex"), "ab".repeat(32), "production", 1);
  await call(a, { brandID: "honey", checkoutID: CHECKOUT, orderID: "gid://shopify/OrderIdentity/18920612135005" });
  let clock = Date.now();
  const logs = [];
  const r = await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: (l) => logs.push(l) });
  assert.deepEqual([r.resolved, r.read, r.moved], [1, 1, 1]);
  const [order] = (await call(a)).data.orders;
  assert.equal(order.state, "shipped");
  assert.equal(order.trackingNumber, "9400111899223197428490");
  assert.equal(order.permalink, PERMALINK);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].aps.alert.title, "Shipped");
  assert.equal(pushes[0].trackedOrder.orderID, "gid://shopify/OrderIdentity/18920612135005");
  assert.ok(logs.some((l) => /get_checkout completed \+order/.test(l)));
  assert.ok(!logs.join("\n").includes("fedcba9876543210"), "no token in the log");

  // Too soon to look again; then the same state sends nothing new.
  assert.equal((await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {} })).orders, 0);
  clock += 46 * 60_000;
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {} });
  assert.equal(pushes.length, 1);

  // A redirect off the brand's sites is not followed.
  redirect = "https://169.254.169.254/latest/meta-data";
  clock += 46 * 60_000;
  const before = calls.length;
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {} });
  assert.ok(!calls.slice(before).some((u) => u.includes("169.254")), "redirect target was fetched");
  assert.match(db.prepare("SELECT diagnosis FROM tracked_orders").get().diagnosis, /redirect-refused/);

  // Delivered ends tracking.
  redirect = null; page = deliveredJSON; clock += 46 * 60_000;
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {} });
  assert.equal(pushes.at(-1).aps.alert.title, "Delivered");
  assert.ok(db.prepare("SELECT done FROM tracked_orders").get().done);
});

test("an unpaid checkout is asked about for two hours, then waits, open, for a tracking number", async (t) => {
  const fetcher = async () => new Response(JSON.stringify({ result: { structuredContent: { id: CHECKOUT, status: "requires_escalation" } } }),
    { status: 200, headers: { "content-type": "application/json" } });
  const { db, call } = await fixture(t, { fetcher });
  await call(key("c"), { brandID: "honey", checkoutID: CHECKOUT });
  let clock = Date.now();
  const logs = [];
  await checkTrackedOrders(db, { fetcher, lookup, now: () => clock, log: (l) => logs.push(l) });
  assert.match(logs[0], /get_checkout requires_escalation no order/);
  assert.equal(db.prepare("SELECT done FROM tracked_orders").get().done, null);
  clock += 2 * 60 * 60_000 + 1;
  await checkTrackedOrders(db, { fetcher, lookup, now: () => clock, log: () => {} });
  const row = db.prepare("SELECT done, resolved, diagnosis FROM tracked_orders").get();
  assert.equal(row.done, null, "kept for a tracking number added later");
  assert.ok(row.resolved);
  assert.match(row.diagnosis, /never returned an order/);
});

// Owner, 2026-10-13: RIPL EFEK #1417 was paid in the app with the express Apple
// Pay button, at a brand with no UCP endpoint: the app never registered it, and
// the wallet's email kept every brand email from the relay.
test("an order at a brand with no UCP checkout registers by its order id and tracks from a number added in the app", async (t) => {
  let fetched = 0;
  const fetcher = async () => { fetched++; return new Response("", { status: 500 }); };
  const pushes = [], registered = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const tracker = Object.assign(async (s) => { registered.push(s); return { id: s.trackingNumber }; }, { service: "17TRACK" });
  const { db, call } = await fixture(t, { fetcher, apns, tracker });
  const a = key("a"), b = key("b"), ORDER = "gid://shopify/OrderIdentity/7461559533591";
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run((await import("node:crypto")).createHash("sha256").update(a).digest("hex"), "ab".repeat(32), "production", 1);
  const reg = await call(a, { brandID: "ripl", orderID: ORDER, itemTitle: "Detergent ◗ Ase", itemCount: 1 });
  assert.equal(reg.status, 201);
  assert.equal(reg.data.orders[0].orderID, ORDER);
  assert.equal((await call(a, { brandID: "ripl", orderID: ORDER })).data.orders.length, 1, "the same order registers once");

  let clock = Date.now();
  const logs = [];
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: (l) => logs.push(l), tracker, budget: trackerBudget(db, {}) });
  assert.equal(fetched, 0, "no get_checkout or page fetch without a UCP checkout");
  assert.match(logs.join("\n"), /no UCP checkout, order id only/);
  clock += 3 * 60 * 60_000;
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {}, tracker, budget: trackerBudget(db, {}) });
  assert.equal(db.prepare("SELECT done FROM tracked_orders").get().done, null, "still open");

  assert.equal((await call(a, { orderID: ORDER, trackingNumber: "<script>" }, "PUT", "/tracking")).status, 400);
  assert.equal((await call(a, { orderID: "nope", trackingNumber: "1LSD0VW001F9GHU" }, "PUT", "/tracking")).status, 400);
  assert.equal((await call(b, { orderID: ORDER, trackingNumber: "1LSD0VW001F9GHU" }, "PUT", "/tracking")).status, 404, "another install's order");
  assert.equal((await call(null, { orderID: ORDER, trackingNumber: "1LSD0VW001F9GHU" }, "PUT", "/tracking")).status, 401);
  const added = await call(a, { orderID: ORDER, trackingNumber: "1lsd 0vw0-01f9ghu" }, "PUT", "/tracking");
  assert.equal(added.status, 200);
  const [o] = added.data.orders;
  assert.equal(o.state, "shipped");
  assert.equal(o.carrier, "OnTrac");
  assert.equal(o.trackingNumber, "1LSD0VW001F9GHU");
  assert.equal(o.trackingURL, "https://www.ontrac.com/tracking/?number=1LSD0VW001F9GHU");
  assert.deepEqual(registered, [{ trackingNumber: "1LSD0VW001F9GHU", carrier: "OnTrac" }]);
  await call(a, { orderID: ORDER, trackingNumber: "1LSD0VW001F9GHU" }, "PUT", "/tracking");
  assert.equal(registered.length, 1, "the same number is registered once");

  await track17Update(db, { event: "TRACKING_UPDATED", data: { number: "1LSD0VW001F9GHU", track_info: { latest_status: { status: "Delivered" } } } },
    { apns, lookup, log: () => {} });
  assert.equal((await call(a)).data.orders[0].state, "delivered");
  assert.equal(pushes.at(-1).aps.alert.body, "Your Detergent ◗ Ase from RIPL EFEK was delivered.");
});

// Owner, 2026-10-07: a tracking number read off the order page goes to 17TRACK,
// and its pushes carry the order the rest of the way.
test("the page's tracking number becomes one 17TRACK tracker, and its pushes move the order and notify", async (t) => {
  const fetcher = async (url, opts) => {
    if (String(url).includes("/api/ucp/mcp")) {
      const id = JSON.parse(opts.body).params.arguments.id;
      return new Response(JSON.stringify({ result: { structuredContent: { id, status: "completed",
        order: { id: "gid://shopify/Order/18920612135005", permalink_url: PERMALINK } } } }), { status: 200, headers: { "content-type": "application/json" } });
    }
    return new Response(shippedPage, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } });
  };
  const pushes = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const { db, call } = await fixture(t, { fetcher, apns });
  const a = key("a");
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run((await import("node:crypto")).createHash("sha256").update(a).digest("hex"), "ab".repeat(32), "production", 1);
  await call(a, { brandID: "honey", checkoutID: CHECKOUT, orderID: "gid://shopify/OrderIdentity/18920612135005" });
  const registered = [];
  const tracker = Object.assign(async (t) => { registered.push(t); return { id: t.trackingNumber }; }, { service: "17TRACK" });
  const budget = trackerBudget(db, { TRACKER_DAILY_MAX: "5" });
  let clock = Date.now();
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {}, tracker, budget });
  assert.deepEqual(registered, [{ trackingNumber: "9400111899223197428490", carrier: "USPS" }]);
  clock += 60 * 60_000;
  await checkTrackedOrders(db, { apns, fetcher, lookup, now: () => clock, log: () => {}, tracker, budget });
  assert.equal(registered.length, 1, "registered once");

  const push = (status, sub) => track17Update(db, { event: "TRACKING_UPDATED", data: { number: "9400111899223197428490",
    track_info: { latest_status: { status, sub_status: sub } } } }, { apns, lookup, log: () => {} });
  const before = pushes.length;
  await push("InTransit", "InTransit_Other");          // already shipped: nothing new
  await push("Exception", "Exception_Damage");
  await push("Exception", "Exception_Damage");          // same problem: once
  await push("OutForDelivery", "OutForDelivery_Other");
  await push("Delivered", "Delivered_Other");
  assert.deepEqual(pushes.slice(before).map((p) => p.aps.alert.title), ["Delivery problem", "Out for delivery", "Delivered"]);
  const [order] = (await call(a)).data.orders;
  assert.equal(order.state, "delivered");
  assert.equal(await push("Delivered", "Delivered_Other"), 0, "a delivered order is done");
});

test("a page tracker reuses a number the relay already follows, and stops at the shared daily cap", async () => {
  const db = new Database(":memory:");
  installTrackingSchema(db);
  db.exec("CREATE TABLE relay_events (tracking_number TEXT, tracker_id TEXT)");
  db.prepare("INSERT INTO relay_events VALUES('1Z999AA10123456784','1Z999AA10123456784')").run();
  const add = (n) => db.prepare("INSERT INTO tracked_orders(device,brand_id,checkout_id,created,tracking_number,state) VALUES('d','honey',?,0,?,'shipped')").run(`c${n}`, n);
  add("1Z999AA10123456784"); add("9400111899223197428490");
  const registered = [], logs = [];
  const tracker = Object.assign(async (t) => { registered.push(t.trackingNumber); return { id: t.trackingNumber }; }, { service: "17TRACK" });
  const budget = trackerBudget(db, { TRACKER_DAILY_MAX: "0" });
  const { startPageTracker } = await import("../server/order-tracking.js");
  for (const row of db.prepare("SELECT * FROM tracked_orders").all()) await startPageTracker(db, row, { tracker, budget, log: (l) => logs.push(l) });
  assert.deepEqual(registered, [], "no quota spent: one reused, one over the cap");
  assert.equal(db.prepare("SELECT tracker_id FROM tracked_orders WHERE checkout_id='c1Z999AA10123456784'").get().tracker_id, "1Z999AA10123456784");
  assert.ok(logs.some((l) => /daily cap reached \(0\)/.test(l)));
});

test("Shipped names the item the app sent: \"KOBA skincare shipped your Keep It Together Headband\"", async (t) => {
  assert.equal(itemPhrase("Keep It Together Headband", 1), "Keep It Together Headband");
  assert.equal(itemPhrase("Keep It Together Headband", 3), "Keep It Together Headband and 2 more items");
  assert.equal(itemPhrase("Headband", 2), "Headband and 1 more item");
  assert.equal(itemPhrase("  bad\u0000\nname ", 1), "bad name", "control characters can't shape the banner");
  assert.equal(itemPhrase("", 1), null);
  assert.equal(pushText("shipped", "KOBA skincare", null, "Keep It Together Headband").body, "KOBA skincare shipped your Keep It Together Headband");
  assert.equal(pushText("shipped", "KOBA skincare", "#1042").body, "KOBA skincare shipped your order #1042.", "no item: the old wording");

  const pushes = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const { db, call } = await fixture(t, { apns });
  const a = key("e");
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run((await import("node:crypto")).createHash("sha256").update(a).digest("hex"), "ab".repeat(32), "production", 1);
  assert.equal((await call(a, { brandID: "honey", checkoutID: CHECKOUT, itemTitle: 42 })).status, 400);
  assert.equal((await call(a, { brandID: "honey", checkoutID: CHECKOUT, itemTitle: "x", itemCount: 0 })).status, 400);
  assert.equal((await call(a, { brandID: "honey", checkoutID: CHECKOUT, orderID: "gid://shopify/OrderIdentity/18920612135005",
    itemTitle: "Keep It Together Headband", itemCount: 1 })).status, 201);
  const row = db.prepare("SELECT * FROM tracked_orders").get();
  assert.deepEqual([row.item_title, row.item_count], ["Keep It Together Headband", 1]);
  db.prepare("UPDATE tracked_orders SET tracker_id='T1', state='confirmed'").run();
  await track17Update(db, { event: "TRACKING_UPDATED", data: { number: "T1", track_info: { latest_status: { status: "InTransit" } } } },
    { apns, lookup, log: () => {} });
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].aps.alert.body, "The Honey Pot shipped your Keep It Together Headband");
  assert.equal(pushes[0].trackedOrder.orderID, "gid://shopify/OrderIdentity/18920612135005", "the tap opens this order");
});

test("items named after the fact reach the order's pushes, matched by order number", async (t) => {
  assert.equal(pushText("delivered", "KOBA skincare", null, "Le Discovery Set").body, "Your Le Discovery Set from KOBA skincare was delivered.");
  const pushes = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const { db, call } = await fixture(t, { apns });
  const a = key("f"), other = key("0");
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run((await import("node:crypto")).createHash("sha256").update(a).digest("hex"), "ab".repeat(32), "production", 1);
  await call(a, { brandID: "honey", checkoutID: CHECKOUT, orderID: "gid://shopify/OrderIdentity/17374756274563" });
  assert.equal((await call(a, { orderID: "nope", itemTitle: "x" }, "PATCH", "/items")).status, 400);
  assert.equal((await call(other, { orderID: "gid://shopify/Order/17374756274563", itemTitle: "X" }, "PATCH", "/items")).data.updated, 0, "another install can't name this one's order");
  const r = await call(a, { orderID: "gid://shopify/Order/17374756274563", itemTitle: "Le Discovery Set", itemCount: 1 }, "PATCH", "/items");
  assert.equal(r.data.updated, 1, "Order and OrderIdentity ids share the number");
  db.prepare("UPDATE tracked_orders SET tracker_id='T2', state='shipped'").run();
  await track17Update(db, { event: "TRACKING_UPDATED", data: { number: "T2", track_info: { latest_status: { status: "OutForDelivery" } } } }, { apns, lookup, log: () => {} });
  assert.equal(pushes.at(-1).aps.alert.body, "Your Le Discovery Set from The Honey Pot is out for delivery.");
});

test("EasyPost updates move an order-page order like 17TRACK's", async (t) => {
  const pushes = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const { db, call } = await fixture(t, { apns });
  const a = key("1");
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run((await import("node:crypto")).createHash("sha256").update(a).digest("hex"), "ab".repeat(32), "production", 1);
  await call(a, { brandID: "honey", checkoutID: CHECKOUT, itemTitle: "Keep It Together Headband", itemCount: 1 });
  db.prepare("UPDATE tracked_orders SET tracker_id='trk_9', state='shipped'").run();
  const logs = [];
  const update = (status, description = "tracker.updated") => easyPostUpdate(db, { description, result: { id: "trk_9", status } }, { apns, lookup, log: (l) => logs.push(l) });
  assert.equal(await update("out_for_delivery", "tracker.created"), 0, "only tracker.updated counts");
  assert.equal(await update("out_for_delivery"), 1);
  await update("out_for_delivery");
  await update("delivered");
  assert.deepEqual(pushes.map((p) => p.aps.alert.body), ["Your Keep It Together Headband from The Honey Pot is out for delivery.", "Your Keep It Together Headband from The Honey Pot was delivered."]);
  assert.ok(logs.some((l) => /shipped -> out_for_delivery \[EasyPost\]/.test(l)));
  assert.equal(await update("delivered"), 0, "a delivered order is done");
});

test("an order at a brand later taken out of the catalog stays open on carrier tracking, and closes once delivered", async (t) => {
  const pushes = [];
  const apns = { configured: () => true, send: async (device, payload) => { pushes.push(payload); return { status: 200 }; } };
  const { db } = await fixture(t, { apns });
  const device = "c".repeat(64);
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?)").run(device, "ab".repeat(32), "production", 1);
  // The Butter Bar, removed 2026-10-13 after order #79242 shipped.
  const insert = (n) => db.prepare(`INSERT INTO tracked_orders(device, brand_id, checkout_id, order_gid, state, carrier, tracking_number, created)
    VALUES(?, 'the-butter-bar-skincare', ?, ?, ?, ?, ?, ?)`).run(device, `gid://shopify/OrderIdentity/${n}`, `gid://shopify/OrderIdentity/${n}`,
      n === 1 ? "shipped" : null, n === 1 ? "USPS" : null, n === 1 ? "92001902673388001077758823" : null, Date.now()).lastInsertRowid;
  const shipped = insert(1), waiting = insert(2);
  const registered = [];
  const tracker = Object.assign(async (s) => { registered.push(s); return { id: s.trackingNumber }; }, { service: "17TRACK" });
  const budget = trackerBudget(db, { TRACKER_DAILY_MAX: "5" });
  let fetched = 0;
  const fetcher = async () => { fetched++; return new Response("", { status: 500 }); };
  const run = () => checkTrackedOrders(db, { apns, fetcher, lookup, log: () => {}, tracker, budget });
  await run();
  const row = (id) => db.prepare("SELECT * FROM tracked_orders WHERE id=?").get(id);
  assert.equal(row(shipped).done, null, "a brand missing from the catalog no longer closes the order");
  assert.equal(row(waiting).done, null, "an order with no number yet stays open for one");
  assert.equal(row(shipped).tracker_id, "92001902673388001077758823");
  assert.deepEqual(registered, [{ trackingNumber: "92001902673388001077758823", carrier: "USPS" }]);
  assert.match(row(shipped).diagnosis, /carrier tracking only/);
  assert.equal(fetched, 0, "no status page or UCP call without a brand record");
  await track17Update(db, { event: "TRACKING_UPDATED", data: { number: "92001902673388001077758823",
    track_info: { latest_status: { status: "Delivered", sub_status: "Delivered_Other" } } } }, { apns, lookup, log: () => {} });
  assert.equal(row(shipped).state, "delivered");
  assert.ok(row(shipped).done);
  assert.match(pushes.at(-1).aps.alert.body, /The Butter Bar Skincare order was delivered/);
  assert.equal(brandNameFor("honey", lookup), "The Honey Pot");
});

// 2026-11-12: any link that merely contained a carrier's name was taken as
// the tracking link.
test("a tracking link is a link on a carrier's own domain", () => {
  assert.equal(carrierLink('<a href="https://tools.usps.com/go/TrackConfirmAction?tLabels=94001">Track</a>'), "https://tools.usps.com/go/TrackConfirmAction?tLabels=94001");
  assert.equal(carrierLink('<a href="https://evil.example/redirect?to=ups.com">Track</a>'), null);
  assert.equal(carrierLink('<a href="https://ups.com.evil.example/track">Track</a>'), null);
  assert.equal(carrierLink('<a href="https://notfedex.com/track">Track</a>'), null);
  assert.equal(carrierLink('<a href="https://user@www.ups.com/track">Track</a>'), null);
  assert.equal(carrierLink('<a href="https://evil.example/?to=ups.com">x</a> <a href="https://www.ups.com/track?tracknum=1Z">Track</a>'), "https://www.ups.com/track?tracknum=1Z");
  assert.equal(carrierLink("no links here"), null);
});
