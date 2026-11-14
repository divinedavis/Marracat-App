import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { brandFresh, freshDiff, freshProduct, freshReport, freshStats, freshTarget } from "../server/brand-fresh.js";

// A brand's live catalog for phones that refresh it faster (owner, 2026-10-20).
const brand = { id: "tel", name: "Telfar", domain: "telfar.net", currency: "USD", platform: "shopify" };
const shopify = (id, extra = {}) => ({ id, title: `Bag ${id}`, handle: `bag-${id}`, product_type: "Bag",
  images: [{ src: "https://cdn.shopify.com/a.jpg" }], published_at: "2026-10-20T00:00:00Z",
  variants: [{ id: id * 10, title: "Small", price: "150.00", compare_at_price: "200.00", available: true },
             { id: id * 10 + 1, title: "Large", price: "202.00", compare_at_price: null, available: false }], ...extra });

test("a Shopify product comes back in the catalog's shape", () => {
  const p = freshProduct(brand, shopify(7));
  assert.equal(p.id, "tel-7");
  assert.equal(p.price, 150, "the cheapest option in stock");
  assert.equal(p.compare_at, 200);
  assert.equal(p.available, true);
  assert.equal(p.variants.length, 2);
  assert.equal(p.url, "https://telfar.net/products/bag-7");
  assert.equal(p.category, "", "departments are the full build's job");
  assert.equal(freshProduct(brand, shopify(8, { title: "Gift Card" })), null, "the catalog's skip list applies");
  assert.equal(freshProduct(brand, shopify(9, { images: [] })), null, "no photo, no product");
});

test("only Shopify brands with a plain domain are asked", () => {
  assert.ok(freshTarget(brand));
  assert.equal(freshTarget({ ...brand, platform: "bigcartel" }), null);
  assert.equal(freshTarget({ ...brand, domain: "http://evil.example/x" }), null);
  assert.equal(freshTarget(null), null);
});

test("one fetch per brand is shared by every phone for five minutes", async () => {
  let calls = 0, t = 0;
  const fetchImpl = async (url) => {
    calls++;
    assert.match(url, /^https:\/\/telfar\.net\/products\.json\?limit=250&page=1$/);
    return { ok: true, text: async () => JSON.stringify({ products: [shopify(1), shopify(2)] }) };
  };
  const fresh = brandFresh({ lookup: { brandRecord: (id) => (id === "tel" ? brand : null) }, fetchImpl, now: () => t,
    limiter: (_d, run) => run() });
  const [a, b] = await Promise.all([fresh.get("tel"), fresh.get("tel")]);
  assert.equal(calls, 1, "two phones at once, one fetch");
  assert.equal(a.products.length, 2);
  assert.deepEqual(a, b);
  t = 4 * 60_000; await fresh.get("tel");
  assert.equal(calls, 1, "still fresh at four minutes");
  t = 6 * 60_000; await fresh.get("tel");
  assert.equal(calls, 2, "asked again after five");
  assert.equal(await fresh.get("nope"), null);
  assert.equal(await fresh.get("../etc"), null, "ids are checked");
});

test("each store fetch counts what it caught that the catalog doesn't show", async () => {
  const db = new Database(":memory:");
  let t = Date.parse("2026-10-21T12:00:00Z"), fail = false;
  const catalog = { "tel-1": { price: 150, compare_at: 200, available: true },   // unchanged
                    "tel-2": { price: 160, compare_at: 200, available: false } }; // price + stock moved
  const fetchImpl = async () => (fail ? { ok: false } :
    { ok: true, text: async () => JSON.stringify({ products: [shopify(1), shopify(2), shopify(3)] }) });
  const fresh = brandFresh({ lookup: { brandRecord: (id) => (id === "tel" ? brand : null), productRecord: (id) => catalog[id] },
    fetchImpl, now: () => t, limiter: (_d, run) => run(), stats: freshStats(db, { now: () => t }) });
  assert.deepEqual(freshDiff([freshProduct(brand, shopify(2))], (id) => catalog[id]), { price: 1, stock: 1, added: 0 });
  await fresh.get("tel"); await fresh.get("tel");
  t += 6 * 60_000; fail = true; await fresh.get("tel");
  await fresh.get("nope");
  const r = freshReport(db, "2026-10-21");
  assert.equal(r.asks, 3, "an unknown brand isn't counted");
  assert.equal(r.fetches, 2, "the second ask came from the cache");
  assert.equal(r.failures, 1);
  assert.equal(r.changed, 1);
  assert.deepEqual([r.price, r.stock, r.added], [1, 1, 1], "tel-3 is new");
  assert.equal(r.by_brand[0].brand, "tel");
});
