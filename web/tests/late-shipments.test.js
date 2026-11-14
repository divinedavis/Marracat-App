import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { createHash } from "node:crypto";
import { lateShipmentRoutes } from "../server/late-shipments.js";

const brands = { scotch: { id: "scotch", name: "Scotch Porter" } };
const lookup = (id) => brands[id];
const key = (c) => c.repeat(64);
const sha = (v) => createHash("sha256").update(v).digest("hex");

async function fixture(t) {
  const db = new Database(":memory:");
  // What mobileSessionUser reads: one owner session, one shopper session.
  db.exec(`CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT);
    CREATE TABLE mobile_sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE mobile_accounts (user_id TEXT PRIMARY KEY, generation TEXT NOT NULL);`);
  for (const [id, email, token] of [["apple:owner", "owner@example.com", key("1")], ["apple:shopper", "shopper@example.com", key("2")]]) {
    db.prepare("INSERT INTO users VALUES(?,?,?)").run(id, null, email);
    db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(sha(token), id, Date.now() + 60_000);
    db.prepare("INSERT INTO mobile_accounts VALUES(?,?)").run(id, "g");
  }
  const app = express();
  lateShipmentRoutes(app, db, { lookup, env: { OWNER_EMAILS: "owner@example.com" } });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => { server.close(); db.close(); });
  const base = `http://127.0.0.1:${server.address().port}/api/orders/late`;
  const call = async (device, body, { method = "POST", token } = {}) => {
    const headers = { "Content-Type": "application/json" };
    if (device) headers["X-Marracat-Device"] = device;
    if (token) headers.Authorization = "Bearer " + token;
    const r = await fetch(base, { method, headers, body: JSON.stringify(body) });
    return r.status;
  };
  return { db, call };
}

test("a late shipment is counted once per order per install, without the order itself", async (t) => {
  const { db, call } = await fixture(t);
  const order = "6D1C2A9E-0B7F-4E3A-9C55-2F1A8B0C4D11";
  assert.equal(await call(key("a"), { brandID: "scotch", order }), 201);
  assert.equal(await call(key("a"), { brandID: "scotch", order }), 201);
  assert.equal(await call(key("b"), { brandID: "scotch", order: "gid://shopify/OrderIdentity/8622093435066" }), 201);
  const rows = db.prepare("SELECT * FROM late_shipments ORDER BY created").all();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].brand_name, "Scotch Porter");
  assert.ok(!JSON.stringify(rows).includes(order) && !JSON.stringify(rows).includes("8622093435066"));
});

test("undo removes only that install's report", async (t) => {
  const { db, call } = await fixture(t);
  const order = "order-1";
  await call(key("a"), { brandID: "scotch", order });
  await call(key("b"), { brandID: "scotch", order });
  assert.equal(await call(key("a"), { order }, { method: "DELETE" }), 200);
  assert.deepEqual(db.prepare("SELECT device FROM late_shipments").all().map((r) => r.device), [sha(key("b"))]);
});

test("deleting the account forgets every report from that install", async (t) => {
  const { db, call } = await fixture(t);
  await call(key("a"), { brandID: "scotch", order: "o1" });
  await call(key("a"), { brandID: "scotch", order: "o2" });
  await call(key("b"), { brandID: "scotch", order: "o1" });
  assert.equal(await call(key("a"), { all: true }, { method: "DELETE" }), 200);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM late_shipments").get().n, 1);
});

test("the owner's own reports are flagged so the dashboard leaves them out", async (t) => {
  const { db, call } = await fixture(t);
  await call(key("a"), { brandID: "scotch", order: "o1" }, { token: key("1") });
  await call(key("b"), { brandID: "scotch", order: "o2" }, { token: key("2") });
  await call(key("c"), { brandID: "scotch", order: "o3" }, { token: key("9") });
  assert.deepEqual(db.prepare("SELECT owner FROM late_shipments ORDER BY order_hash").all().map((r) => r.owner).sort(), [0, 0, 1]);
});

test("bad input is refused", async (t) => {
  const { db, call } = await fixture(t);
  assert.equal(await call(null, { brandID: "scotch", order: "o" }), 401);
  assert.equal(await call("nothex", { brandID: "scotch", order: "o" }), 401);
  assert.equal(await call(key("a"), { brandID: "nobody", order: "o" }), 422);
  assert.equal(await call(key("a"), { brandID: "scotch", order: "<script>" }), 400);
  assert.equal(await call(key("a"), { brandID: "scotch", order: "x".repeat(121) }), 400);
  assert.equal(await call(key("a"), { brandID: "scotch" }), 400);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM late_shipments").get().n, 0);
});
