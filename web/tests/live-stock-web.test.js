import { test } from "node:test";
import assert from "node:assert/strict";
import { withLiveStock, fetchLiveStock } from "../src/live-stock.js";

// The catalog said sold out; the store said back (Sienna Naturals, 2026-10-11).
const catalogSays = { id: "p1", title: "H.A.P.I. Scalp", price: 228, compare_at: 317, available: false,
  variants: [{ id: 51739067744487, title: "Default Title", price: 228, compare_at: 317, available: false }] };

test("the store's live stock and price replace the catalog's", () => {
  const p = withLiveStock(catalogSays, { id: "p1", live: true, available: true,
    variants: [{ id: 51739067744487, title: "Default Title", available: true, price: 200, compare_at: 317 }] });
  assert.equal(p.available, true);
  assert.deepEqual(p.variants[0], { id: 51739067744487, title: "Default Title", price: 200, compare_at: 317, available: true });
  assert.equal(catalogSays.available, false, "the catalog record isn't mutated");
});

test("stock without a price (other currencies) keeps the catalog's price", () => {
  const p = withLiveStock(catalogSays, { id: "p1", live: true, available: true, variants: [{ id: 51739067744487, available: true }] });
  assert.equal(p.variants[0].price, 228);
  assert.equal(p.variants[0].available, true);
});

test("sold out at the store reads sold out, even when the catalog says available", () => {
  const p = withLiveStock({ ...catalogSays, available: true, variants: [{ ...catalogSays.variants[0], available: true }] },
    { id: "p1", live: true, available: false, variants: [{ id: 51739067744487, available: false }] });
  assert.equal(p.available, false);
  assert.equal(p.variants[0].available, false);
});

test("no answer, a live:false answer, or another product's answer leaves the catalog alone", () => {
  assert.equal(withLiveStock(catalogSays, null), catalogSays);
  assert.equal(withLiveStock(catalogSays, { id: "p1", live: false }), catalogSays);
  assert.equal(withLiveStock(catalogSays, { id: "p2", live: true, available: true, variants: [] }), catalogSays);
  assert.equal(withLiveStock(undefined, { id: "p1", live: true, variants: [] }), undefined);
});

test("options the catalog left out come from the store", () => {
  const p = withLiveStock({ id: "p1", price: 20, available: true }, { id: "p1", live: true, available: true,
    variants: [{ id: 1, title: "S", available: false, price: 20, compare_at: null }, { id: 2, title: "M", available: true, price: 22, compare_at: null }] });
  assert.deepEqual(p.variants.map((v) => [v.title, v.available, v.price]), [["S", false, 20], ["M", true, 22]]);
});

test("the fetch asks the stock route uncached and swallows failures", async () => {
  const seen = [];
  const ok = await fetchLiveStock("a b", { fetchImpl: async (url, init) => { seen.push([url, init.cache]); return { ok: true, json: async () => ({ id: "a b", live: true }) }; } });
  assert.deepEqual(seen, [["/api/products/a%20b/stock", "no-store"]]);
  assert.equal(ok.live, true);
  assert.equal(await fetchLiveStock("x", { fetchImpl: async () => ({ ok: false }) }), null);
  assert.equal(await fetchLiveStock("x", { fetchImpl: async () => { throw new Error("offline"); } }), null);
  assert.equal(await fetchLiveStock("x", { fetchImpl: async () => ({ ok: true, json: async () => ({ id: "y" }) }) }), null);
});
