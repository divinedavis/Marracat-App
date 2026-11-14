import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { cartRoutes, cleanLines } from "../server/cart-sync.js";

test("cart lines keep only known fields, in range, without repeats", () => {
  const lines = cleanLines([
    { productID: "p1", variantID: 4312, quantity: 2, unitPrice: 9.5, currency: "USD", option: "M", extra: "x" },
    { productID: "p1", variantID: "4312", quantity: 1 },
  ]);
  assert.deepEqual(lines, [{ productID: "p1", variantID: "4312", quantity: 2, option: "M", unitPrice: 9.5, currency: "USD" }]);
  assert.equal(cleanLines([{ productID: "p1", variantID: "abc", quantity: 1 }]), null);
  assert.equal(cleanLines([{ productID: "p1", variantID: "1", quantity: 0 }]), null);
  assert.equal(cleanLines(Array.from({ length: 101 }, (_, i) => ({ productID: "p" + i, variantID: "1", quantity: 1 }))), null);
});

async function server(user) {
  const app = express();
  const db = new Database(":memory:");
  let t = 1000;
  cartRoutes(app, db, { viewer: async (req) => (req.get("X-User") ? { id: req.get("X-User") } : null), now: () => ++t });
  const s = app.listen(0);
  await new Promise((r) => s.once("listening", r));
  const base = `http://127.0.0.1:${s.address().port}/api/cart`;
  const call = (method, body, who = user) => fetch(base, { method, headers: { "Content-Type": "application/json", ...(who ? { "X-User": who } : {}) }, body: body && JSON.stringify(body) });
  return { call, close: () => s.close() };
}

test("one account's cart is the same from the website and the app", async () => {
  const { call, close } = await server("u1");
  try {
    assert.equal((await call("GET", null, null)).status, 401, "signed out");
    assert.deepEqual(await (await call("GET")).json(), { lines: [], updated: 0 });
    const put = await (await call("PUT", { lines: [{ productID: "p1", variantID: "9", quantity: 3 }] })).json();
    assert.ok(put.updated > 0);
    const got = await (await call("GET")).json();
    assert.deepEqual(got.lines, [{ productID: "p1", variantID: "9", quantity: 3 }]);
    assert.equal(got.updated, put.updated);
    assert.deepEqual((await (await call("GET", null, "u2")).json()).lines, [], "another account's cart is its own");
    assert.equal((await call("PUT", { lines: "nope" })).status, 400);
  } finally { close(); }
});
