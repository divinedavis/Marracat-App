import { test } from "node:test";
import assert from "node:assert/strict";
import {
  validateBuyer, validateLines, endpointFor, createArguments, parseCheckout, buildBrandCheckout, PROFILE_URL,
} from "../server/checkout.js";

const buyer = {
  firstName: "Test", lastName: "Buyer", email: "test@example.com", phone: "7185550100",
  street: "1 Main St", extended: "", city: "Brooklyn", region: "NY", postalCode: "11201",
};
const brand = { id: "karbon-footprint", name: "Karbon Footprint", domain: "karbonfootprint.myshopify.com",
  currency: "USD", ucp: "https://karbon-footprint.myshopify.com/api/ucp/mcp" };

// Trimmed from Hope for Flowers' real reply on 2026-09-21: shipping priced,
// phone number still wanted, isError set anyway.
const storeReply = {
  jsonrpc: "2.0", id: 1,
  result: { isError: true, content: [{ type: "text", text: "…" }], structuredContent: {
    ucp: { version: "2026-08-25" },
    id: "gid://shopify/Checkout/abc?key=k", status: "incomplete", currency: "USD",
    continue_url: "https://hope-for-flowers-by-tr.myshopify.com/cart/c/abc?key=share",
    expires_at: "2026-10-21T18:51:51Z",
    totals: [{ type: "subtotal", amount: 24800 }, { type: "fulfillment", amount: 684 }, { type: "total", amount: 25484 }],
    messages: [{ type: "error", code: "delivery_phone_number_required", content: "Enter a phone number to use this delivery method", severity: "recoverable" }],
    fulfillment: { methods: [{ id: "s", type: "shipping", groups: [{ id: "g", selected_option_id: "o1",
      options: [{ id: "o1", title: "UPS® Ground", totals: [{ type: "total", amount: 684 }] }] }] }] },
  } },
};

test("buyer and lines are validated and trimmed; bad input is refused", () => {
  const b = validateBuyer({ ...buyer, firstName: " Test " });
  assert.equal(b.firstName, "Test");
  assert.equal(b.country, "US");
  assert.throws(() => validateBuyer({ ...buyer, email: "nope" }), /email/);
  assert.throws(() => validateBuyer({ ...buyer, phone: "x" }), /phone/);
  assert.throws(() => validateBuyer({ ...buyer, street: "" }), /street/);
  assert.deepEqual(validateLines([{ variant: 123, quantity: 2 }]), [{ variant: "123", quantity: 2 }]);
  assert.throws(() => validateLines([{ variant: "abc", quantity: 1 }]));
  assert.throws(() => validateLines([{ variant: "1", quantity: 100 }]));
  assert.throws(() => validateLines([]));
});

test("only a store's own UCP endpoint from the catalog is called", () => {
  assert.ok(endpointFor(brand));
  assert.equal(endpointFor({ ...brand, ucp: "http://karbon-footprint.myshopify.com/api/ucp/mcp" }), null);
  assert.equal(endpointFor({ ...brand, ucp: "https://evil.example/api/ucp/mcp" }), null);
  assert.equal(endpointFor({ ...brand, ucp: "https://karbon-footprint.myshopify.com/admin" }), null);
  assert.ok(endpointFor({ ...brand, domain: "hopeforflowers.com", ucp: "https://hopeforflowers.com/api/ucp/mcp" }));
  assert.equal(endpointFor({ ...brand, ucp: undefined }), null);
});

test("the request names the hosted profile, GID variants, a phone on buyer and destination, web attribution", () => {
  const a = createArguments("USD", [{ variant: "51998231003349", quantity: 2 }], validateBuyer(buyer));
  assert.equal(a.meta["ucp-agent"].profile, PROFILE_URL);
  assert.equal(a.checkout.line_items[0].item.id, "gid://shopify/ProductVariant/51998231003349");
  assert.equal(a.checkout.buyer.phone_number, "7185550100");
  const dest = a.checkout.fulfillment.methods[0].destinations[0];
  assert.equal(dest.address_locality, "Brooklyn");
  assert.equal(dest.phone_number, "7185550100");
  assert.ok(!("extended_address" in dest));
  assert.equal(a.checkout.attribution.utm_medium, "web");
});

test("a store reply is parsed, including one flagged isError that is still usable", () => {
  const c = parseCheckout(storeReply);
  assert.equal(c.status, "incomplete");
  assert.equal(c.total, 25484);
  assert.equal(c.shipping, 684);
  assert.equal(c.shippingOption, "UPS® Ground");
  assert.equal(new URL(c.continueUrl).hostname, "hope-for-flowers-by-tr.myshopify.com");
  assert.equal(c.messages[0].code, "delivery_phone_number_required");
  assert.ok(c.needsAttention);
});

test("store errors surface the store's reason with a 502", () => {
  assert.throws(() => parseCheckout({ error: { code: -32001, message: "UCP discovery failed", data: { content: "Unable to fetch agent profile" } } }),
    (e) => e.status === 502 && /agent profile/.test(e.message));
  assert.throws(() => parseCheckout({ result: { content: [{ type: "text", text: "nope" }] } }), (e) => e.status === 502);
});

test("buildBrandCheckout posts JSON-RPC to the store and maps the reply", async () => {
  let seen;
  const fetcher = async (url, init) => {
    seen = { url, init };
    return { ok: true, status: 200, headers: { get: () => "application/json" }, text: async () => JSON.stringify(storeReply) };
  };
  const c = await buildBrandCheckout({ brand, lines: validateLines([{ variant: "1", quantity: 1 }]), buyer: validateBuyer(buyer) }, fetcher);
  assert.equal(seen.url, brand.ucp);
  const body = JSON.parse(seen.init.body);
  assert.equal(body.method, "tools/call");
  assert.equal(body.params.name, "create_checkout");
  assert.equal(c.total, 25484);
  await assert.rejects(buildBrandCheckout({ brand: { ...brand, ucp: null }, lines: [], buyer }, fetcher), (e) => e.status === 409);
  await assert.rejects(buildBrandCheckout({ brand, lines: [{ variant: "1", quantity: 1 }], buyer }, async () => ({ ok: false, status: 500, headers: { get: () => "" }, text: async () => "" })), (e) => e.status === 502);
});

test("SSE-framed replies are read from their last data line", async () => {
  const fetcher = async () => ({
    ok: true, status: 200, headers: { get: () => "text/event-stream" },
    text: async () => "event: message\ndata: " + JSON.stringify(storeReply) + "\n\n",
  });
  const c = await buildBrandCheckout({ brand, lines: [{ variant: "1", quantity: 1 }], buyer: validateBuyer(buyer) }, fetcher);
  assert.equal(c.total, 25484);
});

// Opt-in: builds a real checkout at a brand's store (no order placed). REAL_UCP=1 to run.
test("a real store builds a checkout from saved details", { skip: process.env.REAL_UCP !== "1" }, async () => {
  const c = await buildBrandCheckout({ brand, lines: [{ variant: "47248505634985", quantity: 1 }], buyer: validateBuyer(buyer) });
  console.log("REAL UCP:", c.status, c.total, c.shippingOption, c.continueUrl);
  assert.ok(c.continueUrl);
  assert.ok(c.total > 0);
});

// Audit 2026-10-07 (L2): only a signed-in shopper or the website itself may
// build checkouts, with per-brand caps a guest can't use up for others.
test("checkout/build needs a session or the website's own fetch, and is capped per brand", async () => {
  const express = (await import("express")).default;
  const { checkoutRoutes, BUILDS_PER_IP_BRAND } = await import("../server/checkout.js");
  const app = express();
  let user = null, builds = 0;
  checkoutRoutes(app, { viewer: async () => user, env: { PUBLIC_URL: "https://marracat.com" },
    lookup: (id) => (id === "b1" ? { id: "b1" } : null), build: async () => ({ id: "c" + ++builds }) });
  const s = app.listen(0, "127.0.0.1"); await new Promise((r) => s.once("listening", r));
  const buyer = { firstName: "A", lastName: "B", street: "1 Main St", city: "X", region: "NY", postalCode: "10001", email: "a@b.co", phone: "+12125551212" };
  const post = (headers = {}) => fetch(`http://127.0.0.1:${s.address().port}/api/checkout/build`, { method: "POST",
    headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify({ brand: "b1", lines: [{ variant: "1", quantity: 1 }], buyer }) });
  try {
    assert.equal((await post()).status, 401, "a script with no session and no same-origin browser");
    for (let i = 0; i < BUILDS_PER_IP_BRAND; i++) assert.equal((await post({ "Sec-Fetch-Site": "same-origin" })).status, 200);
    assert.equal((await post({ "Sec-Fetch-Site": "same-origin" })).status, 429, "per IP per brand");
    user = { id: "u1" };
    assert.equal((await post()).status, 429, "the per-IP cap holds signed in too");
  } finally { s.close(); }
});

test("guests together can't exceed the brand's hourly cap; signed-in shoppers aren't blocked by it", async () => {
  const { buildLimiter, BUILDS_PER_BRAND_HOUR } = await import("../server/checkout.js");
  const allow = buildLimiter(() => 0);
  for (let i = 0; i < BUILDS_PER_BRAND_HOUR; i++) assert.equal(allow({ ip: "ip" + i, brandID: "b1" }), true);
  assert.equal(allow({ ip: "fresh", brandID: "b1" }), false);
  assert.equal(allow({ ip: "fresh2", brandID: "b1", signedIn: true }), true);
});

// 2026-11-12: one map held address and brand counts and was emptied at
// 20,000 keys, so a flood of addresses reset every brand's hourly cap.
test("a flood of addresses can't reset a brand's hourly cap; the oldest address is forgotten first", async () => {
  const { buildLimiter, BUILDS_PER_BRAND_HOUR, BUILDS_PER_IP_BRAND } = await import("../server/checkout.js");
  const allow = buildLimiter(() => 0, 50);
  for (let i = 0; i < BUILDS_PER_BRAND_HOUR; i++) assert.ok(allow({ ip: `10.0.${i}.1`, brandID: "koba", signedIn: false }));
  assert.ok(!allow({ ip: "10.9.9.9", brandID: "koba", signedIn: false }), "the brand's cap holds after 120 addresses");
  for (let i = 0; i < 200; i++) allow({ ip: `10.1.${i}.1`, brandID: `brand${i}`, signedIn: true });
  assert.ok(!allow({ ip: "10.9.9.8", brandID: "koba", signedIn: false }), "and after a flood past the map's size");
  const one = buildLimiter(() => 0, 50);
  for (let i = 0; i < BUILDS_PER_IP_BRAND; i++) assert.ok(one({ ip: "1.1.1.1", brandID: "koba", signedIn: true }));
  assert.ok(!one({ ip: "1.1.1.1", brandID: "koba", signedIn: true }));
});
