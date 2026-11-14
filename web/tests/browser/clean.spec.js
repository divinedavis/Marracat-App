import { test, expect } from "./fixtures.js";

const toggle = (page) => page.getByRole("checkbox", { name: /Marracat Clean/ });

test("the Marracat Clean toggle narrows a category to badged products", async ({ page }) => {
  await page.goto("/#/shop?category=skincare");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 30000 });
  await toggle(page).check();
  await expect(page.locator(".product-card").first()).toBeVisible();
  const cards = await page.locator(".product-card").count();
  const badged = await page.locator(".product-card .clean-badge").count();
  expect(cards).toBeGreaterThan(0);
  expect(badged).toBe(cards);
});

// Since 7860119 the toggle shows only where something listed carries the
// badge (owner, 2026-10-04: no Clean filter on earrings).
test("aisles with nothing badged get no Clean toggle", async ({ page }) => {
  await page.goto("/#/shop?q=durag");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 30000 });
  await expect(page.locator(".product-card .clean-badge")).toHaveCount(0);
  await expect(toggle(page)).toHaveCount(0);
});
