import { test, expect } from "./fixtures.js";

// Live store stock on product pages (5fd9ad6, owner 2026-10-11): the page
// asks /api/products/<id>/stock and lays the store's answer over the
// catalog's, which can be hours old. The page tests stub the route so they
// hold whatever the store says today; the contract test asks the real one.

const stockURL = (id) => "/api/products/" + encodeURIComponent(id) + "/stock";

async function shopifyProduct(request, available) {
  const c = await (await request.get("/api/catalog?v=5")).json();
  const shopify = new Set(c.brands.filter((b) => b.shopify).map((b) => b.id));
  const p = c.products.find((x) => x.available === available && x.images?.length && shopify.has(x.brand)
    && (x.variants || []).length === 1 && x.variants[0].available === available);
  expect(p, `no ${available ? "in-stock" : "sold-out"} single-option Shopify product in the catalog`).toBeTruthy();
  return p;
}

test("the stock route answers for a catalog product, uncached, and refuses unknown ids", async ({ request }) => {
  const p = await shopifyProduct(request, true);
  const r = await request.get(stockURL(p.id));
  expect(r.status()).toBe(200);
  expect(r.headers()["cache-control"]).toBe("no-store");
  const body = await r.json();
  expect(body.id).toBe(p.id);
  expect(typeof body.live).toBe("boolean");
  if (body.live) {
    expect(typeof body.available).toBe("boolean");
    expect(Array.isArray(body.variants)).toBe(true);
  }
  expect((await request.get(stockURL("not-a-product-id"))).status()).toBe(404);
});

test("a product the catalog has sold out is buyable when the store has it back", async ({ page, request }) => {
  const p = await shopifyProduct(request, false);
  const v = p.variants[0];
  await page.route("**" + stockURL(p.id), (r) => r.fulfill({ json:
    { id: p.id, live: true, available: true, variants: [{ id: v.id, title: v.title, available: true }], checked_at: new Date().toISOString() } }));
  await page.goto("/p/" + encodeURIComponent(p.id));
  await expect(page.locator(".detail-actions .primary-button")).toBeEnabled({ timeout: 30000 });
});

test("a product the store has sold out can't be added, whatever the catalog says", async ({ page, request }) => {
  const p = await shopifyProduct(request, true);
  const v = p.variants[0];
  await page.route("**" + stockURL(p.id), (r) => r.fulfill({ json:
    { id: p.id, live: true, available: false, variants: [{ id: v.id, title: v.title, available: false }], checked_at: new Date().toISOString() } }));
  await page.goto("/p/" + encodeURIComponent(p.id));
  await expect(page.locator(".product-detail")).toBeVisible({ timeout: 30000 });
  await expect(page.locator(".detail-actions .primary-button")).toBeDisabled({ timeout: 15000 });
});

test("no live answer leaves the catalog's stock", async ({ page, request }) => {
  const p = await shopifyProduct(request, true);
  await page.route("**" + stockURL(p.id), (r) => r.fulfill({ json: { id: p.id, live: false } }));
  await page.goto("/p/" + encodeURIComponent(p.id));
  await expect(page.locator(".detail-actions .primary-button")).toBeEnabled({ timeout: 30000 });
});
