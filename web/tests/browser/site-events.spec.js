import { test, expect } from "./fixtures.js";

// The website reports what visitors do to /api/events (server/events.js).
test("opening a product, adding it and searching each send one event, plus a screen_view per page", async ({ page, request }) => {
  const c = await (await request.get("/api/catalog?v=5")).json();
  const p = c.products.find((x) => x.available && x.images?.length && c.brands.find((b) => b.id === x.brand)?.shopify
    && (x.variants || []).some((v) => v.available));
  const sent = [];
  await page.route("**/api/events", async (r) => { sent.push(JSON.parse(r.request().postData())); await r.fulfill({ status: 204 }); });
  // The page lays the store's live stock over the catalog (live-stock.spec.js);
  // whether this product is in stock at its store today isn't this test's
  // business (2026-10-13: the cap it picked had sold out, and Add stayed off).
  await page.route(`**/api/products/${encodeURIComponent(p.id)}/stock`, (r) => r.fulfill({ json: { id: p.id, live: false } }));
  await page.goto(`/p/${p.id}`);
  const add = page.locator(".detail-actions .primary-button");
  await expect(add).toBeEnabled({ timeout: 60000 });
  await add.click();
  await page.goto("/shop?q=shea%20butter");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 60000 });
  // Each page also sends a screen_view (EVENTS.md); the actions are one event each.
  const actions = () => sent.filter((e) => !["screen_view", "rec_view"].includes(e.e)).map((e) => e.e).sort();
  await expect.poll(actions).toEqual(["add_to_cart", "product_open", "search"]);
  const screens = sent.filter((e) => e.e === "screen_view").map((e) => e.screen);
  expect(screens).toContain("product");
  expect(screens).toContain("search");
  expect(sent.find((e) => e.e === "screen_view" && e.screen === "product").product).toBe(p.id);
  expect(sent.find((e) => e.e === "product_open").product).toBe(p.id);
  expect(sent.find((e) => e.e === "search").q).toBe("shea butter");
  expect(new Set(sent.map((e) => e.id)).size).toBe(1);
});
