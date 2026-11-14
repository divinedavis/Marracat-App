import { test, expect } from "./fixtures.js";

// Owner, 2026-11-08: "as i move down the site the filtering should be moving
// down with me": the Filters / Currency / Sort row stays under the header,
// and on wide screens so does the filter column (product type, badges…).
async function scrolled(page, viewport) {
  await page.setViewportSize(viewport);
  await page.goto("/b/fear-of-god");
  await expect(page.locator(".shop-toolbar")).toBeVisible({ timeout: 60000 });
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 60000 });
  await page.mouse.wheel(0, 2400);
  await page.waitForTimeout(800);
  return page.evaluate(() => {
    const box = (s) => { const e = document.querySelector(s); const r = e.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, height: r.height }; };
    return { y: scrollY, header: box(".header"), toolbar: box(".shop-toolbar"), side: box(".filter-side") };
  });
}

test("desktop: the toolbar and the filter column stay in view", async ({ page }) => {
  const r = await scrolled(page, { width: 1440, height: 900 });
  expect(r.y).toBeGreaterThan(1500);
  expect(Math.abs(r.toolbar.top - r.header.bottom)).toBeLessThan(2);
  expect(r.side.top).toBeGreaterThanOrEqual(r.toolbar.bottom);
  expect(r.side.top).toBeLessThan(400);
  expect(r.side.bottom).toBeLessThanOrEqual(900);
  await expect(page.getByText("Marracat badges")).toBeInViewport();
});

test("phone: Filters, currency and Sort stay under the header", async ({ page }) => {
  const r = await scrolled(page, { width: 390, height: 844 });
  expect(r.y).toBeGreaterThan(1500);
  expect(Math.abs(r.toolbar.top - r.header.bottom)).toBeLessThan(2);
  await expect(page.locator(".filters-toggle")).toBeInViewport();
});
