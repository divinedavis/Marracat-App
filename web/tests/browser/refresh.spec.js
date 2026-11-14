import { test, expect } from "./fixtures.js";
test("monochrome storefront and browser icons are published without the old wording", async ({
  page,
  request,
}) => {
  await page.goto("/");
  await expect(page.locator(".hero-main")).toBeVisible({ timeout: 30000 });
  await expect(page.locator("body")).not.toContainText(/black[\s-]*owned/i);
  await expect(page).toHaveTitle(
    "Marracat | Your next favorite. All in one place.",
  );
  expect(
    await page
      .locator(".header")
      .evaluate((el) => getComputedStyle(el).backgroundColor),
  ).toBe("rgb(17, 17, 17)");
  for (const path of [
    "/favicon.ico?v=2",
    "/favicon-32.png?v=2",
    "/apple-touch-icon.png?v=2",
  ]) {
    const response = await request.get(path);
    expect(response.status()).toBe(200);
    expect(response.headers()["content-type"]).toMatch(/image\//);
  }
  await page.goto("/#/brands");
  // All brands waits for the full catalog (its product counts), like saved
  // items in storefront.spec.js; how fast it draws is held there.
  await expect(page.locator(".brand-card").first()).toBeVisible({ timeout: 30000 });
  await expect(page.locator("body")).not.toContainText(/black[\s-]*owned/i);
});
test("products append on scroll, keep their order, and reset when filtering", async ({
  page,
}) => {
  await page.goto("/#/shop");
  const cards = page.locator(".product-grid .product-card");
  await expect(cards).toHaveCount(36, { timeout: 30000 });
  const first = await cards
    .first()
    .locator(".product-title")
    .getAttribute("href");
  await page.getByTestId("scroll-sentinel").scrollIntoViewIfNeeded();
  await expect(cards).toHaveCount(72);
  expect(
    await cards.first().locator(".product-title").getAttribute("href"),
  ).toBe(first);
  const ids = await cards
    .locator(".product-title")
    .evaluateAll((links) => links.map((a) => a.href));
  expect(new Set(ids).size).toBe(ids.length);
  await page.getByTestId("scroll-sentinel").scrollIntoViewIfNeeded();
  // While the sentinel stays on screen it can load several pages in a row, so
  // check the grid grew by whole pages rather than by exactly one.
  await expect.poll(() => cards.count()).toBeGreaterThan(72);
  expect((await cards.count()) % 36).toBe(0);
  // The brand filter is a type-to-search picker; a misspelling still finds it.
  await page.getByRole("button", { name: "Filter by brand" }).click();
  await page.getByRole("combobox", { name: "Search brands" }).fill("brwon girl jane");
  await page.getByRole("combobox", { name: "Search brands" }).press("Enter");
  await expect(page.getByRole("button", { name: "Filter by brand" })).toHaveText("Brown Girl Jane");
  // However many products the brand has today (18 until 2026-10-31, then
  // 20): the grid holds them all, and the status line says the same number.
  await expect(page.getByRole("status")).toContainText(/explored all \d+/);
  const all = Number((await page.getByRole("status").innerText()).match(/explored all (\d+)/)[1]);
  expect(all).toBeGreaterThan(0);
  await expect(cards).toHaveCount(all);
});
test("mobile homepage discovery feed also loads automatically", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const cards = page.locator(".discovery-feed .product-card");
  await expect(cards).toHaveCount(36, { timeout: 30000 });
  await page.getByTestId("scroll-sentinel").scrollIntoViewIfNeeded();
  await expect(cards).toHaveCount(72);
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBeTruthy();
});
