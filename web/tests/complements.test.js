import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import {
  complementRoutes, shopifyID, storeHost, cartComplements, fetchLimiter, CACHE_MS, MAX,
} from "../server/complements.js";
import { recordEvent, cleanEvent } from "../server/events.js";

// A tiny catalog: KOBA on Shopify, a Big Cartel brand, one sold-out product.
const products = new Map();
const add = (id, brand, extra = {}) => products.set(id, { id, brand, title: id, price: 10, available: true, images: [`https://img/${id}.jpg`], category: "skincare", ...extra });
for (let i = 1; i <= 15; i++) add(`koba-skincare-${100 + i}`, "koba-skincare");
add("koba-skincare-999", "koba-skincare", { available: false });
add("cartel-a", "cartel");
add("cartel-b", "cartel", { category: "home" });
const brands = {
  "koba-skincare": { id: "koba-skincare", domain: "kobaskincare.com", platform: "shopify", shopify: true },
  cartel: { id: "cartel", domain: "cartel.bigcartel.com", platform: "bigcartel" },
};
const recs = (ids) => new Response(JSON.stringify({ products: ids.map((id) => ({ id, title: String(id) })) }), { status: 200 });

async function server(t, fetchImpl, { now = Date.now } = {}) {
  const db = new Database(":memory:");
  const app = express();
  complementRoutes(app, db, { lookup: (id) => products.get(id), brandOf: (id) => brands[id], fetchImpl, now });
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => { s.close(); db.close(); });
  const get = async (id) => {
    const r = await fetch(`http://127.0.0.1:${s.address().port}/api/products/${encodeURIComponent(id)}/complements`);
    return { status: r.status, body: r.status === 200 ? await r.json() : null };
  };
  return { db, get };
}

test("catalog ids map to Shopify ids only for that brand's numeric suffix", () => {
  assert.equal(shopifyID("koba-skincare-7334563479734", "koba-skincare"), "7334563479734");
  assert.equal(shopifyID("koba-skincare-abc", "koba-skincare"), null);
  assert.equal(shopifyID("other-brand-123", "koba-skincare"), null);
});

test("only plain public domains from the catalog are fetched (no IPs, ports or paths)", () => {
  assert.equal(storeHost({ domain: "kobaskincare.com" }), "kobaskincare.com");
  assert.equal(storeHost({ domain: "https://www.brand.co.uk/" }), "www.brand.co.uk");
  for (const domain of ["127.0.0.1", "169.254.169.254", "localhost", "brand.com:8080", "user@brand.com", "", "a b.com"])
    assert.equal(storeHost({ domain }), null, domain);
});

test("Shopify's complementary picks come first, mapped to catalog ids, in stock, without the product itself", async (t) => {
  const urls = [];
  const { get } = await server(t, async (url) => {
    urls.push(url);
    return recs([102, 103, 101, 999, 777777, 104, 105]);
  });
  const { status, body } = await get("koba-skincare-101");
  assert.equal(status, 200);
  assert.deepEqual(body.products, ["koba-skincare-102", "koba-skincare-103", "koba-skincare-104", "koba-skincare-105"],
    "self, sold out and unknown products dropped");
  assert.equal(body.source, "shopify");
  assert.equal(body.intent, "complementary");
  assert.equal(body.items[0].id, "koba-skincare-102");
  assert.equal(urls.length, 1);
  assert.equal(urls[0], "https://kobaskincare.com/recommendations/products.json?product_id=101&intent=complementary&limit=10");
});

test("no complementary picks falls back to related", async (t) => {
  const { get } = await server(t, async (url) => (url.includes("complementary") ? recs([]) : recs([106, 107])));
  const { body } = await get("koba-skincare-101");
  assert.deepEqual(body.products, ["koba-skincare-106", "koba-skincare-107"]);
  assert.equal(body.intent, "related");
});

test("the brand's answer is cached for a day; the store isn't asked again", async (t) => {
  let calls = 0, clock = 1_000_000;
  const { get } = await server(t, async () => { calls++; return recs([102]); }, { now: () => clock });
  await get("koba-skincare-101");
  await get("koba-skincare-101");
  assert.equal(calls, 1);
  clock += CACHE_MS + 1;
  await get("koba-skincare-101");
  assert.equal(calls, 2, "refetched after 24 hours");
});

test("a store that fails or redirects off its domain gives no picks, never an error", async (t) => {
  const { get } = await server(t, async (url) => {
    if (url.includes("101")) throw new Error("timeout");
    return new Response("", { status: 301, headers: { location: "http://169.254.169.254/latest/meta-data" } });
  });
  for (const id of ["koba-skincare-101", "koba-skincare-102"]) {
    const { status, body } = await get(id);
    assert.equal(status, 200);
    assert.deepEqual(body.products, []);
  }
});

test("a redirect within the brand's own domain is followed once", async (t) => {
  const { get } = await server(t, async (url) => (url.startsWith("https://kobaskincare.com/")
    ? new Response("", { status: 301, headers: { location: url.replace("https://kobaskincare.com", "https://www.kobaskincare.com") } })
    : recs([108])));
  assert.deepEqual((await get("koba-skincare-101")).body.products, ["koba-skincare-108"]);
});

test("non-Shopify brands never fetch; carts need three different shoppers", async (t) => {
  let calls = 0;
  const { db, get } = await server(t, async () => { calls++; return recs([]); });
  const now = Date.now();
  for (const v of ["a", "b"]) {
    recordEvent(db, v.repeat(20), cleanEvent({ e: "add_to_cart", product: "cartel-a" }), now);
    recordEvent(db, v.repeat(20), cleanEvent({ e: "add_to_cart", product: "cartel-b" }), now + 60_000);
  }
  assert.deepEqual((await get("cartel-a")).body.products, [], "two shoppers aren't enough");
  recordEvent(db, "c".repeat(20), cleanEvent({ e: "add_to_cart", product: "cartel-a" }), now);
  recordEvent(db, "c".repeat(20), cleanEvent({ e: "add_to_cart", product: "cartel-b" }), now + 60_000);
  // A cart pair made days apart isn't a session.
  recordEvent(db, "d".repeat(20), cleanEvent({ e: "add_to_cart", product: "cartel-a" }), now);
  recordEvent(db, "d".repeat(20), cleanEvent({ e: "add_to_cart", product: "koba-skincare-101" }), now + 3 * 86_400_000);
  const { body } = await get("cartel-a");
  assert.deepEqual(body.products, ["cartel-b"]);
  assert.equal(body.source, "carts");
  assert.equal(calls, 0, "no fetch for a non-Shopify brand");
});

test("app cart pairs (pair_installs) count too, and mix with the brand's picks", async (t) => {
  const { db, get } = await server(t, async () => recs([102]));
  for (const d of ["x", "y", "z"]) db.prepare("INSERT INTO pair_installs(a,b,device,created) VALUES(?,?,?,?)").run("cartel-b", "koba-skincare-101", d, 1);
  assert.deepEqual(cartComplements(db, "koba-skincare-101"), ["cartel-b"]);
  const { body } = await get("koba-skincare-101");
  assert.deepEqual(body.products, ["koba-skincare-102", "cartel-b"]);
  assert.equal(body.source, "mixed");
});

test("at most twelve products; bad and unknown ids are refused", async (t) => {
  const { get } = await server(t, async () => recs(Array.from({ length: 15 }, (_, i) => 101 + i)));
  assert.equal((await get("koba-skincare-115")).body.products.length, Math.min(MAX, 14));
  assert.ok([400, 404].includes((await get("../etc/passwd")).status), "a path-like id is refused");
  assert.equal((await get("bad id!")).status, 400);
  assert.equal((await get("no-such-product")).status, 404);
});

test("the fetch limiter runs one request per domain at a time", async () => {
  const limit = fetchLimiter(4);
  let running = 0, peak = 0;
  const job = () => limit("same.com", async () => {
    running++; peak = Math.max(peak, running);
    await new Promise((r) => setTimeout(r, 5));
    running--;
    return 1;
  });
  await Promise.all([job(), job(), job()]);
  assert.equal(peak, 1);
});
