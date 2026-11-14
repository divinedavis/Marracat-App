import { test, expect } from "./fixtures.js";

// Hovering a product photo on a computer shows a lens over it and that spot
// magnified over the details column, as on Amazon (owner, 2026-10-04); each
// photo in the editorial grid keeps it (2026-11-09).
test("desktop: hovering the product photo zooms it beside the photo", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const id = await page.evaluate(async () => {
    const { products } = await (await fetch("/api/catalog?v=3")).json();
    return products.find((p) => p.available && p.images?.length).id;
  });
  await page.goto("/#/product?id=" + encodeURIComponent(id));
  const img = page.locator(".photo-grid img").first();
  await expect(img).toBeVisible({ timeout: 30000 });
  await page.waitForFunction(() => document.querySelector(".photo-grid img")?.naturalWidth > 0);
  const box = await img.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.move(box.x + box.width / 2 + 4, box.y + box.height / 2 + 4);
  const pane = page.locator(".zoom-pane");
  await expect(page.locator(".zoom-lens")).toBeVisible();
  await expect(pane).toBeVisible();
  const paneBox = await pane.boundingBox();
  expect(paneBox.x).toBeGreaterThanOrEqual(box.x + box.width);
  await page.mouse.move(2, 2);
  await expect(pane).toHaveCount(0);
});
