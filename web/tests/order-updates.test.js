import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { accountWebRoutes, orderUpdates } from "../server/account-web.js";
import { installMobileSchema } from "../server/mobile.js";
import { installTrackingSchema } from "../server/order-tracking.js";
import { toAppleDate } from "../src/orderRecord.js";
import { orderKey, updatesFor, stepOf, headline, arrivalLabel, describe, safeLink } from "../src/orderUpdates.js";

// Website order details match shipping updates to orders the way the app does
// (RelayStore.events(for:), OrderTrackingStore.tracked(for:)); owner, 2026-10-11.
const KOBA = { id: "koba", name: "KOBA skincare", domain: "kobaskincare.com" };
const at = (iso) => Date.parse(iso);
const order = (id, iso, extra = {}) => ({ id, brandID: "koba", date: toAppleDate(at(iso)), itemCount: 1, subtotal: 10, ...extra });

test("one order number however the brand writes it", () => {
  assert.equal(orderKey("#KOBA-11906"), "11906");
  assert.equal(orderKey("#11906"), "11906");
  assert.equal(orderKey("11906"), "11906");
});

test("two orders from one brand a minute apart each get their own emails", () => {
  const a = order("A", "2026-10-07T15:00:00Z"), b = order("B", "2026-10-07T15:01:00Z");
  const events = [
    { id: 1, received: at("2026-10-07T15:00:30Z"), kind: "confirmation", brandDomain: "kobaskincare.com", orderName: "#11905" },
    { id: 2, received: at("2026-10-07T15:01:30Z"), kind: "confirmation", brandDomain: "kobaskincare.com", orderName: "#11906" },
    { id: 3, received: at("2026-10-08T12:00:00Z"), kind: "shipped", brandDomain: "kobaskincare.com", orderName: "#KOBA-11906", carrier: "USPS", trackingNumber: "9400" },
    { id: 4, received: at("2026-10-08T12:00:00Z"), kind: "shipped", brandDomain: "other.com", orderName: "#1" },
  ];
  const forA = updatesFor(a, KOBA, [a, b], { events }).events.map((e) => e.id);
  const forB = updatesFor(b, KOBA, [a, b], { events }).events.map((e) => e.id);
  assert.deepEqual(forA, [1]);
  assert.deepEqual(forB, [2, 3], "the shipped email names B's number in another spelling");
  assert.equal(stepOf(updatesFor(b, KOBA, [a, b], { events }).events), 1);
});

test("the brand's own order page counts when it has shipped", () => {
  const r = order("C", "2026-10-05T10:00:00Z", { orderID: "gid://shopify/OrderIdentity/18930295275769" });
  const tracked = [{ brandID: "koba", orderID: "gid://shopify/Order/18930295275769", state: "delivered", created: at("2026-10-05T10:00:00Z"), updated: at("2026-10-07T18:00:00Z"), statusPage: "https://koba.example/orders/x" }];
  const u = updatesFor(r, KOBA, [r], { events: [], tracked });
  assert.equal(u.tracked.statusPage, "https://koba.example/orders/x");
  assert.equal(stepOf(u.events), 3);
  assert.match(headline(3, u.events, at("2026-10-05T10:00:00Z")), /^Delivered /);
});

test("words and links for the page", () => {
  assert.equal(arrivalLabel("2026-10-11", new Date(2026, 9, 11)), "Arriving today");
  assert.equal(arrivalLabel("2026-10-12", new Date(2026, 9, 11)), "Arriving tomorrow");
  assert.equal(arrivalLabel("2026-10-01", new Date(2026, 9, 11)), null);
  assert.equal(describe({ kind: "shipped", carrier: "UPS", trackingNumber: "1Z" }), "Shipped · UPS");
  assert.equal(safeLink("javascript:alert(1)"), null);
  assert.equal(safeLink("http://x.com"), null);
});

test("GET /api/account/orders/updates: only the signed-in account's updates", async () => {
  const db = new Database(":memory:");
  installMobileSchema(db);
  installTrackingSchema(db);
  db.exec("CREATE TABLE restock_links (device TEXT PRIMARY KEY, user_id TEXT NOT NULL, updated INTEGER NOT NULL)");
  db.prepare("INSERT INTO restock_links VALUES (?,?,?)").run("dev-u1", "u1", 1);
  db.prepare("INSERT INTO restock_links VALUES (?,?,?)").run("dev-u2", "u2", 1);
  const ins = db.prepare("INSERT INTO tracked_orders(device,brand_id,checkout_id,order_gid,permalink,state,created) VALUES (?,?,?,?,?,?,?)");
  ins.run("dev-u1", "koba", "secret-checkout-1", "gid://shopify/Order/1", "https://koba.example/s/1", "shipped", 1);
  ins.run("dev-u2", "koba", "secret-checkout-2", "gid://shopify/Order/2", "https://koba.example/s/2", "shipped", 2);
  const relay = { events: (id) => (id === "u1" ? [{ id: 9, kind: "confirmation" }] : []) };
  const got = orderUpdates(db, relay, "u1");
  assert.deepEqual(got.events.map((e) => e.id), [9]);
  assert.deepEqual(got.tracked.map((t) => t.orderID), ["gid://shopify/Order/1"]);
  assert.ok(!JSON.stringify(got).includes("secret-checkout"), "checkout ids are credentials and never leave");

  const app = express();
  accountWebRoutes(app, db, { relay, viewer: async (req) => (req.get("X-User") ? { id: req.get("X-User") } : null) });
  const s = app.listen(0); await new Promise((r) => s.once("listening", r));
  const base = `http://127.0.0.1:${s.address().port}/api/account/orders/updates`;
  try {
    assert.equal((await fetch(base)).status, 401);
    const body = await (await fetch(base, { headers: { "X-User": "u2" } })).json();
    assert.deepEqual(body.tracked.map((t) => t.orderID), ["gid://shopify/Order/2"]);
    assert.deepEqual(body.events, []);
  } finally { s.close(); }
});
