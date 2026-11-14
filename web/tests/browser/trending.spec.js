import { test, expect } from "./fixtures.js";

// "Trending now" on the home page (owner, 2026-10-10), fed by /api/trending
// (server/trending.js), routed here so the test doesn't depend on traffic.
const products = (n) => Array.from({ length: n }, (_, i) => ({
  id: `trend-test-${i}`, title: `Trend Test Item ${i}`, brand: "Test Brand", price: 20 + i,
  currency: "USD", images: [], available: true, category: "beauty",
}));

test("the home page shows the Trending now row with six or more products", async ({ page }) => {
  await page.route("**/api/trending*", (r) => r.fulfill({ json: { title: "Trending now", basis: "momentum", products: products(6) } }));
  await page.goto("/");
  const row = page.getByTestId("trending-row");
  await expect(row).toBeVisible({ timeout: 60000 });
  await expect(row.getByRole("heading", { name: "Trending now" })).toBeVisible();
  await expect(row.locator(".product-card")).toHaveCount(6);
  await expect(row.locator('a[href="/p/trend-test-0"]').first()).toBeVisible();
});

test("the popular fallback keeps its own title", async ({ page }) => {
  await page.route("**/api/trending*", (r) => r.fulfill({ json: { title: "Popular this week", basis: "popular", products: products(7) } }));
  await page.goto("/");
  const row = page.getByTestId("trending-row");
  await expect(row.getByRole("heading", { name: "Popular this week" })).toBeVisible({ timeout: 60000 });
  await expect(row.locator(".product-card")).toHaveCount(7);
});

test("fewer than six products, or an error, hides the row", async ({ page }) => {
  await page.route("**/api/trending*", (r) => r.fulfill({ json: { title: "Trending now", basis: "popular", products: products(5) } }));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 60000 });
  await expect(page.getByTestId("trending-row")).toHaveCount(0);

  await page.unroute("**/api/trending*");
  await page.route("**/api/trending*", (r) => r.fulfill({ status: 500, json: {} }));
  await page.reload();
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 60000 });
  await expect(page.getByTestId("trending-row")).toHaveCount(0);
});
