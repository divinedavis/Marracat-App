import { test, expect } from "./fixtures.js";

// The product page as an editorial grid (owner, 2026-11-09, picked "1
// Editorial grid"): every photo down the left, options as chips, and the
// details column staying in view while the page scrolls ("make sure the right
// side section hovers as the user scrolls down the page").
const SWEATER = "fear-of-god-8017294950461"; // Off Black, XS to XL, 5 photos

test("desktop: all photos show and the details stay in view while scrolling", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/p/" + SWEATER);
  const info = page.locator(".detail-info");
  await expect(info.locator("h1")).toBeVisible({ timeout: 60000 });
  expect(await page.locator(".photo-grid img").count()).toBeGreaterThan(1);
  const before = await info.boundingBox();
  await page.mouse.wheel(0, 900);
  await page.waitForTimeout(400);
  const after = await info.boundingBox();
  expect(after.y).toBeGreaterThan(0);
  expect(after.y).toBeLessThan(before.y);
  await expect(info.getByRole("button", { name: /Add to cart|Shop at/ })).toBeInViewport();
});

test("options are chips: picking a size picks that variant", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/p/" + SWEATER);
  const size = page.getByRole("radiogroup", { name: /Size/ });
  await expect(size).toBeVisible({ timeout: 60000 });
  const chips = size.getByRole("radio");
  expect(await chips.count()).toBeGreaterThan(1);
  const target = chips.nth(1);
  const label = (await target.textContent()).trim();
  await target.click();
  await expect(target).toHaveAttribute("aria-checked", "true");
  await expect(page.locator(".variant-axis-label").nth(1)).toContainText(label);
});

test("the heart saves the product", async ({ page }) => {
  await page.goto("/p/" + SWEATER);
  const save = page.locator(".detail-save");
  await expect(save).toBeVisible({ timeout: 60000 });
  await expect(save).toHaveAttribute("aria-pressed", "false");
  await save.click();
  await expect(save).toHaveAttribute("aria-pressed", "true");
  await expect(save).toHaveAttribute("aria-label", "Saved");
});

test("phone: photos swipe in one row and the details follow below", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/p/" + SWEATER);
  const grid = page.locator(".photo-grid");
  await expect(grid).toBeVisible({ timeout: 60000 });
  const tops = await grid.locator("img").evaluateAll((els) => new Set(els.map((e) => Math.round(e.getBoundingClientRect().top))).size);
  expect(tops).toBe(1);
  await expect(page.locator(".photo-dots i")).not.toHaveCount(0);
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow).toBeLessThanOrEqual(1);
});

// "comments should be vertically aligned with top picks" (owner, 2026-11-09).
test("comments start at the same left edge as the rows under them", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/p/" + SWEATER);
  const comments = page.getByTestId("comments");
  await expect(comments).toBeVisible({ timeout: 60000 });
  const row = page.locator("main .section").first();
  await expect(row).toBeVisible({ timeout: 30000 });
  const [c, r] = [await comments.locator("h2").boundingBox(), await row.locator("h2").boundingBox()];
  expect(Math.abs(c.x - r.x)).toBeLessThanOrEqual(1);
});

// Clicking a photo opens the lightbox (owner, 2026-11-09, picked "1 Lightbox").
test("clicking a photo opens it large; arrows, thumbnails and Esc work", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/p/" + SWEATER);
  const photos = page.locator(".photo-grid img");
  await expect(photos.nth(1)).toBeVisible({ timeout: 60000 });
  await photos.nth(1).click();
  const box = page.locator("dialog.lightbox");
  await expect(box).toBeVisible();
  const count = box.locator(".lightbox-count");
  await expect(count).toContainText(/^2 \/ \d+ · Extrafine/);
  await box.getByRole("button", { name: "Next photo" }).click();
  await expect(count).toContainText(/^3 \//);
  await page.keyboard.press("ArrowLeft");
  await expect(count).toContainText(/^2 \//);
  await box.getByRole("button", { name: "Photo 1", exact: true }).click();
  await expect(count).toContainText(/^1 \//);
  await page.keyboard.press("ArrowLeft");
  await expect(count).toContainText(/^(\d+) \/ \1 /); // wraps to the last
  await page.keyboard.press("Escape");
  await expect(box).toHaveCount(0);
  expect(await page.evaluate(() => document.body.style.overflow)).toBe("");
});

test("phone: tapping a photo opens it, a swipe moves on, Close shuts it", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/p/" + SWEATER);
  const first = page.locator(".photo-grid img").first();
  await expect(first).toBeVisible({ timeout: 60000 });
  await first.click();
  const box = page.locator("dialog.lightbox");
  await expect(box.locator(".lightbox-count")).toContainText(/^1 \//);
  await box.locator(".lightbox-stage").dispatchEvent("touchstart", { touches: [{ identifier: 0, clientX: 300, clientY: 400 }] });
  await box.locator(".lightbox-stage").dispatchEvent("touchend", { changedTouches: [{ identifier: 0, clientX: 120, clientY: 400 }] });
  await expect(box.locator(".lightbox-count")).toContainText(/^2 \//);
  await box.getByRole("button", { name: "Close photos" }).click();
  await expect(box).toHaveCount(0);
});
