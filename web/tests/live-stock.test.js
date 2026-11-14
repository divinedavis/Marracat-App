import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { liveStock, liveStockRoutes, liveStockTarget, liveStockFrom, CACHE_MS, FAIL_CACHE_MS } from "../server/live-stock.js";

// The Sienna Naturals pre-order that started this (owner, 2026-10-11): the
// store said available, the catalog still said sold out.
const products = {
  "sienna-naturals-9444756422887": { id: "sienna-naturals-9444756422887", brand: "sienna", title: "H.A.P.I. Scalp", currency: "USD",
    url: "https://www.siennanaturals.com/products/h-a-p-i-scalp-happy-hair-ritual", available: false },
  gbp: { id: "gbp", brand: "sienna", title: "Pound item", currency: "GBP", url: "https://www.siennanaturals.com/products/pound" },
  cartel: { id: "cartel", brand: "cartel", title: "Print", url: "https://cartel.bigcartel.com/products/print" },
  ip: { id: "ip", brand: "sienna", title: "IP", url: "https://169.254.169.254/products/x" },
  port: { id: "port", brand: "sienna", title: "Port", url: "https://www.siennanaturals.com:8443/products/x" },
  http: { id: "http", brand: "sienna", title: "Plain", url: "http://www.siennanaturals.com/products/x" },
  other: { id: "other", brand: "sienna", title: "Not a product", url: "https://www.siennanaturals.com/admin/x" },
};
const brands = {
  sienna: { id: "sienna", name: "Sienna Naturals", platform: "shopify" },
  cartel: { id: "cartel", name: "Cartel", platform: "bigcartel" },
};
const lookup = { productRecord: (id) => products[id], brandRecord: (id) => brands[id] };
const HAPI = { available: true, variants: [{ id: 51739067744487, title: "Default Title", available: true, price: 22800, compare_at_price: 31700 }] };
const json = (body, status = 200, headers = {}) => new Response(JSON.stringify(body), { status, headers });

async function server(t, fetchImpl, { now = Date.now, limit } = {}) {
  const app = express();
  const stock = liveStock({ lookup, fetchImpl, now });
  liveStockRoutes(app, { stock, lookup, limit });
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => s.close());
  const get = async (id) => {
    const r = await fetch(`http://127.0.0.1:${s.address().port}/api/products/${encodeURIComponent(id)}/stock`);
    const text = await r.text();
    let body = null; try { body = JSON.parse(text); } catch {}
    return { status: r.status, cache: r.headers.get("cache-control"), body };
  };
  return { get, stock };
}

test("only https /products/ URLs from our own catalog, on Shopify, without ports or IPs", () => {
  assert.deepEqual(liveStockTarget("sienna-naturals-9444756422887", lookup),
    { url: "https://www.siennanaturals.com/products/h-a-p-i-scalp-happy-hair-ritual.js", host: "www.siennanaturals.com", currency: "USD" });
  for (const id of ["cartel", "ip", "port", "http", "other", "missing"]) assert.equal(liveStockTarget(id, lookup), null, id);
});

test("the store's cents become dollars; a compare-at no higher than the price is dropped", () => {
  const value = liveStockFrom({ available: false, variants: [
    { id: 1, title: "S", available: true, price: 1999, compare_at_price: 2500 },
    { id: 2, title: "M", available: false, price: 1999, compare_at_price: 1999 },
    { id: "junk", available: true },
  ] });
  assert.deepEqual(value, { available: true, variants: [
    { id: 1, title: "S", available: true, price: 19.99, compare_at: 25 },
    { id: 2, title: "M", available: false, price: 19.99, compare_at: null },
  ] });
  assert.equal(liveStockFrom({ nope: true }), null);
  assert.equal(liveStockFrom({ variants: [] }), null);
});

test("other currencies get stock only: the store prices in the shopper's currency", () => {
  const value = liveStockFrom(HAPI, { currency: "GBP" });
  assert.deepEqual(value.variants, [{ id: 51739067744487, title: "Default Title", available: true }]);
});

test("a restocked pre-order reads as available, live, uncached by browsers", async (t) => {
  const urls = [];
  const { get } = await server(t, async (url) => { urls.push(url); return json(HAPI); });
  const r = await get("sienna-naturals-9444756422887");
  assert.equal(r.status, 200);
  assert.equal(r.cache, "no-store");
  assert.equal(r.body.live, true);
  assert.equal(r.body.available, true);
  assert.deepEqual(r.body.variants, [{ id: 51739067744487, title: "Default Title", available: true, price: 228, compare_at: 317 }]);
  assert.ok(r.body.checked_at);
  assert.deepEqual(urls, ["https://www.siennanaturals.com/products/h-a-p-i-scalp-happy-hair-ritual.js"]);
});

test("one fetch per product per cache window, shared by every shopper", async (t) => {
  let clock = 1_000_000, calls = 0;
  const { get } = await server(t, async () => { calls++; return json(HAPI); }, { now: () => clock });
  await Promise.all([get("sienna-naturals-9444756422887"), get("sienna-naturals-9444756422887"), get("sienna-naturals-9444756422887")]);
  assert.equal(calls, 1, "concurrent pages share one fetch");
  clock += CACHE_MS - 1;
  await get("sienna-naturals-9444756422887");
  assert.equal(calls, 1);
  clock += 2;
  await get("sienna-naturals-9444756422887");
  assert.equal(calls, 2);
});

test("a failing store answers live:false (the page keeps the catalog) and isn't asked again at once", async (t) => {
  let clock = 1_000_000, calls = 0;
  const { get } = await server(t, async () => { calls++; return json({ error: "x" }, 500); }, { now: () => clock });
  assert.deepEqual((await get("sienna-naturals-9444756422887")).body, { id: "sienna-naturals-9444756422887", live: false });
  await get("sienna-naturals-9444756422887");
  assert.equal(calls, 1);
  clock += FAIL_CACHE_MS + 1;
  await get("sienna-naturals-9444756422887");
  assert.equal(calls, 2);
});

test("a thrown fetch or a non-JSON body is live:false too", async (t) => {
  const { get } = await server(t, async () => { throw new Error("timeout"); });
  assert.equal((await get("sienna-naturals-9444756422887")).body.live, false);
  const other = await server(t, async () => new Response("<html>", { status: 200 }));
  assert.equal((await other.get("sienna-naturals-9444756422887")).body.live, false);
});

test("non-Shopify brands fall back without any fetch; unknown and malformed ids are refused", async (t) => {
  let calls = 0;
  const { get } = await server(t, async () => { calls++; return json(HAPI); });
  assert.deepEqual((await get("cartel")).body, { id: "cartel", live: false });
  assert.equal((await get("missing")).status, 404);
  assert.equal((await get("../etc")).status, 400);
  assert.equal((await get("a".repeat(300))).status, 400);
  assert.equal(calls, 0);
});

test("redirects: one hop, same store or myshopify, still a product JSON path", async (t) => {
  const go = (location) => async (url) => (url.includes("siennanaturals.com/products/h-a-p-i") ? new Response(null, { status: 301, headers: { location } }) : json(HAPI));
  for (const [location, live] of [
    ["https://siennanaturals.com/products/new-handle.js", true],
    ["https://sienna.myshopify.com/products/new-handle.js", true],
    ["https://evil.example.com/products/x.js", false],
    ["https://www.siennanaturals.com/admin/api.json", false],
    ["http://www.siennanaturals.com/products/x.js", false],
    ["https://169.254.169.254/products/x.js", false],
    ["https://www.siennanaturals.com:8443/products/x.js", false],
  ]) {
    const { get } = await server(t, go(location));
    assert.equal((await get("sienna-naturals-9444756422887")).body.live, live, location);
  }
});

test("the route is rate limited per address", async (t) => {
  const { get } = await server(t, async () => json(HAPI), { limit: 2 });
  await get("sienna-naturals-9444756422887");
  await get("sienna-naturals-9444756422887");
  assert.equal((await get("sienna-naturals-9444756422887")).status, 429);
});

test("the restock check's read primes the page's answer, so a push and its page agree", async (t) => {
  let calls = 0;
  const { get, stock } = await server(t, async () => { calls++; return json({ available: false, variants: [{ id: 1, available: false, price: 100 }] }); });
  stock.prime("sienna-naturals-9444756422887", HAPI);
  const r = await get("sienna-naturals-9444756422887");
  assert.equal(r.body.available, true);
  assert.equal(calls, 0);
  stock.prime("cartel", HAPI);   // not watchable: ignored
  assert.equal((await get("cartel")).body.live, false);
});
