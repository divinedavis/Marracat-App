import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { parseSwellLines, swellConfig, safeCheckoutURL, createSwellCheckout, swellRoutes, swellShippingQuote } from "../server/swell.js";
import { checkoutURL } from "../src/catalog.js";
import { buyClickFor } from "../src/events.js";

const P = "6a91f2d30942e900131a077b", V = "6a91f2d30942e900131a07b1";
const brand = { id: "yeezy", name: "YEEZY", domain: "yeezy.com", shopify: true, platform: "swell",
  swell: { store: "yzy-prod", key: "pk_UDtBUDIgX4j2StzcMPjwb7pfsmM1deoK" } };
const products = {
  "yeezy-1": { brand: "yeezy", swell_product: P, variants: [
    { id: 358757638017136, swell: V, available: true },
    { id: 42, swell: "6a91f2d30942e900131a07b0", available: false },
  ] },
  "other-1": { brand: "other", swell_product: P, variants: [{ id: 7, swell: V, available: true }] },
};
const lookup = (id) => products[id];

test("Swell hand-off: only this brand's buyable variants, mapped to Swell's ids", () => {
  assert.deepEqual(parseSwellLines("yeezy-1:358757638017136:2", "yeezy", lookup),
    [{ product_id: P, variant_id: V, quantity: 2 }]);
  assert.equal(parseSwellLines("yeezy-1:42:1", "yeezy", lookup), null, "sold out");
  assert.equal(parseSwellLines("yeezy-1:999:1", "yeezy", lookup), null, "unknown variant");
  assert.equal(parseSwellLines("other-1:7:1", "yeezy", lookup), null, "another brand's product");
  assert.equal(parseSwellLines("yeezy-1:358757638017136:0", "yeezy", lookup), null);
  assert.equal(parseSwellLines("<script>:1:1", "yeezy", lookup), null);
});

test("Swell config and checkout hosts are checked, not trusted", () => {
  assert.ok(swellConfig(brand));
  assert.equal(swellConfig({ ...brand, platform: "shopify" }), null);
  assert.equal(swellConfig({ ...brand, swell: { store: "evil.com/x", key: brand.swell.key } }), null);
  assert.equal(swellConfig({ ...brand, swell: { store: "yzy-prod", key: "sk_secret" } }), null);
  assert.ok(safeCheckoutURL("https://yeezy.com/checkout/abc", brand, "yzy-prod"));
  assert.ok(safeCheckoutURL("https://yzy-prod.swell.store/checkout/abc", brand, "yzy-prod"));
  assert.equal(safeCheckoutURL("http://yeezy.com/checkout/abc", brand, "yzy-prod"), false);
  assert.equal(safeCheckoutURL("https://yeezy.com.evil.net/checkout", brand, "yzy-prod"), false);
});

// A stand-in for Swell's storefront API: a cart per session, items added one at a time.
function fakeSwell({ fail } = {}) {
  const calls = [];
  const fetchImpl = async (url, opts) => {
    calls.push({ url, method: opts.method, session: opts.headers["X-Session"], body: JSON.parse(opts.body) });
    if (fail) return new Response(JSON.stringify({ error: { message: "nope" } }), { status: 400 });
    const qty = calls.filter((c) => c.url.endsWith("/cart/items")).reduce((n, c) => n + c.body.quantity, 0);
    const rated = opts.body.includes('"shipping"')
      ? { currency: "USD", shipment_rating: { services: [{ name: "Express", price: 30 }, { name: "Standard Shipping", price: 16.99 }] } } : {};
    return new Response(JSON.stringify({ item_quantity: qty, checkout_url: "https://yeezy.com/checkout/f3a6", ...rated }),
      { headers: { "X-Session": "s1" } });
  };
  return { calls, fetchImpl };
}

test("the cart is built in one Swell session and tagged as Marracat's", async () => {
  const swell = fakeSwell();
  const lines = [{ product_id: P, variant_id: V, quantity: 2 }, { product_id: P, quantity: 1 }];
  const url = await createSwellCheckout(brand.swell, lines, { fetchImpl: swell.fetchImpl, note: "n" });
  assert.equal(url, "https://yeezy.com/checkout/f3a6");
  assert.deepEqual(swell.calls.map((c) => [c.method, c.url.replace("https://yzy-prod.swell.store/api", ""), c.session]),
    [["POST", "/cart/items", undefined], ["POST", "/cart/items", "s1"], ["PUT", "/cart", "s1"]]);
  assert.deepEqual(swell.calls[2].body, { metadata: { referral: "marracat" }, comments: "n" });
  await assert.rejects(createSwellCheckout(brand.swell, lines, { fetchImpl: fakeSwell({ fail: true }).fetchImpl }));
});

async function get(app, path) {
  const server = app.listen(0);
  try {
    return await fetch(`http://127.0.0.1:${server.address().port}${path}`, { redirect: "manual" });
  } finally {
    server.close();
  }
}

test("/go/swell redirects to the brand's checkout, or says why not", async () => {
  const make = (fetchImpl) => {
    const app = express();
    swellRoutes(app, { lookup: { brandRecord: (id) => (id === "yeezy" ? brand : null), productRecord: lookup }, fetchImpl });
    return app;
  };
  const ok = await get(make(fakeSwell().fetchImpl), "/go/swell?brand=yeezy&items=yeezy-1:358757638017136:1");
  assert.equal(ok.status, 303);
  assert.equal(ok.headers.get("location"), "https://yeezy.com/checkout/f3a6");
  assert.equal((await get(make(fakeSwell().fetchImpl), "/go/swell?brand=nobody&items=x:1:1")).status, 404);
  assert.equal((await get(make(fakeSwell().fetchImpl), "/go/swell?brand=yeezy&items=yeezy-1:42:1")).status, 400);
  const down = await get(make(fakeSwell({ fail: true }).fetchImpl), "/go/swell?brand=yeezy&items=yeezy-1:358757638017136:1");
  assert.equal(down.status, 500);
  assert.match(await down.text(), /Shop at YEEZY/);
  const elsewhere = async () => new Response(JSON.stringify({ item_quantity: 1, checkout_url: "https://evil.example/pay" }));
  assert.equal((await get(make(elsewhere), "/go/swell?brand=yeezy&items=yeezy-1:358757638017136:1")).status, 500);
});

test("a Swell quote rates a cart holding only the items and the ZIP, and takes the cheapest", async () => {
  const swell = fakeSwell();
  const quote = await swellShippingQuote(brand.swell, [{ product_id: P, variant_id: V, quantity: 1 }], "11201", { fetchImpl: swell.fetchImpl });
  assert.deepEqual(quote, { amount: 16.99, currency: "USD", title: "Standard Shipping" });
  assert.deepEqual(swell.calls[1].body, { shipping: { zip: "11201", country: "US" } });
  const app = express();
  swellRoutes(app, { lookup: { brandRecord: (id) => (id === "yeezy" ? brand : null), productRecord: lookup }, fetchImpl: fakeSwell().fetchImpl });
  const ok = await get(app, "/api/ship-quote/swell?brand=yeezy&zip=11201&items=yeezy-1:358757638017136:1");
  assert.equal(ok.status, 200);
  assert.equal((await ok.json()).quote.amount, 16.99);
  assert.equal((await get(app, "/api/ship-quote/swell?brand=yeezy&zip=abc&items=yeezy-1:358757638017136:1")).status, 400);
  assert.equal((await get(app, "/api/ship-quote/swell?brand=nobody&zip=11201&items=x:1:1")).status, 404);
  assert.equal((await get(app, "/api/ship-quote/swell?brand=yeezy&zip=11201&items=yeezy-1:42:1")).status, 400);
});

test("the website's checkout link for a Swell brand goes through /go/swell, and counts as a Swell buy", () => {
  const lines = [{ product: { id: "yeezy-1", available: true }, variant: { id: 358757638017136, available: true }, quantity: 2 }];
  assert.equal(checkoutURL(brand, lines), "/go/swell?brand=yeezy&items=yeezy-1%3A358757638017136%3A2");
  assert.equal(checkoutURL(brand, [{ ...lines[0], variant: { id: 1, available: false } }]), null);
  assert.deepEqual(buyClickFor("/go/swell?brand=yeezy&items=x", () => null, "https://marracat.com"), { brand: "yeezy", via: "swell" });
});
