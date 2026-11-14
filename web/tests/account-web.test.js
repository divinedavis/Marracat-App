import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { accountWebRoutes } from "../server/account-web.js";
import { applyOperations, installMobileSchema } from "../server/mobile.js";
import { webOrderRecord, fromAppleDate } from "../src/orderRecord.js";

test("an order placed on the website is a record the app can read", () => {
  const now = Date.UTC(2026, 9, 5, 23, 13);
  const r = webOrderRecord({ brandID: "b", lines: [{ id: "p1", quantity: 2, title: "Soap" }], subtotal: 18, currency: "USD", now });
  assert.equal(fromAppleDate(r.date).getTime(), now, "Swift's 2001-based seconds");
  assert.equal(r.itemCount, 2);
  assert.match(r.id, /^[0-9A-F-]{36}$/);
});

test("the website reads the orders the app saved, and adds its own", async () => {
  const db = new Database(":memory:");
  installMobileSchema(db);
  applyOperations(db, "u1", [{ id: "op1", kind: "checkout", checkout: { id: "A1", brandID: "b1", date: 1, itemCount: 1, subtotal: 9, productIDs: ["p"] } }]);
  const app = express();
  accountWebRoutes(app, db, { viewer: async (req) => (req.get("X-User") ? { id: req.get("X-User") } : null) });
  const s = app.listen(0); await new Promise((r) => s.once("listening", r));
  const base = `http://127.0.0.1:${s.address().port}/api/account`;
  try {
    assert.equal((await fetch(base + "/profile")).status, 401);
    const got = await (await fetch(base + "/profile", { headers: { "X-User": "u1" } })).json();
    assert.deepEqual(got.profile.checkouts.map((c) => c.brandID), ["b1"]);
    const rec = webOrderRecord({ brandID: "b2", lines: [{ id: "p2", quantity: 1, title: "Bag" }], subtotal: 50, currency: "USD" });
    const post = await fetch(base + "/activity", { method: "POST", headers: { "X-User": "u1", "Content-Type": "application/json" },
      body: JSON.stringify({ operations: [{ id: rec.id, kind: "checkout", checkout: rec }] }) });
    assert.deepEqual((await post.json()).profile.checkouts.map((c) => c.brandID), ["b2", "b1"]);
    const bad = await fetch(base + "/activity", { method: "POST", headers: { "X-User": "u1", "Content-Type": "application/json" },
      body: JSON.stringify({ operations: [{ id: "x", kind: "nope" }] }) });
    assert.equal(bad.status, 400);
  } finally { s.close(); }
});
