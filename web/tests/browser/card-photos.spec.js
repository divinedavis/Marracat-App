import { test, expect } from "./fixtures.js";

// Product cards click through a product's photos (owner, 2026-11-09: "can we
// give buttons for people to click through the images of a product on a brand
// screen"), and their lines sit at one spacing so a row lines up ("we need
// uniformity").

// A card on the brand's first page whose product has three or more photos.
// The first card was assumed to: on 2026-11-10 the brand's first product had
// one photo, so its card rightly drew no arrows and two of these tests failed.
async function cardWithPhotos(page) {
  await page.goto("/b/fear-of-god");
  await expect(page.locator(".product-grid .product-card").first()).toBeVisible({ timeout: 60000 });
  const hrefs = await page.locator(".product-grid .product-card .product-art a").evaluateAll((links) => links.slice(0, 24).map((a) => a.getAttribute("href")));
  for (const href of hrefs) {
    const id = decodeURIComponent(href.replace(/^\/p\//, ""));
    const product = await (await page.request.get("/api/products/" + encodeURIComponent(id) + "?v=3")).json();
    if ((product.images || []).length >= 3) return page.locator(".product-grid .product-card").filter({ has: page.locator(`.product-art a[href="${href}"]`) }).first();
  }
  throw Error("no card on /b/fear-of-god's first page has three photos");
}

test("a brand page card steps through its photos without leaving the page", async ({ page }) => {
  const card = await cardWithPhotos(page);
  const img = card.locator(".product-art img");
  const first = await img.getAttribute("src");
  await card.locator(".product-art").hover();
  const next = card.getByRole("button", { name: /^Next photo of / });
  await expect(next).toBeVisible();
  await next.click();
  await expect(card.locator(".card-photo-count")).toHaveText(/^2\/\d+$/);
  await expect(img).not.toHaveAttribute("src", first);
  await card.getByRole("button", { name: /^Previous photo of / }).click();
  await expect(card.locator(".card-photo-count")).toHaveText(/^1\/\d+$/);
  await expect(img).toHaveAttribute("src", first);
  await expect(page).toHaveURL(/\/b\/fear-of-god$/);
});

test("cards in a grid row line up their brand, title and price", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto("/b/fear-of-god");
  const cards = page.locator(".product-grid .product-card");
  await expect(cards.nth(3)).toBeVisible({ timeout: 60000 });
  const tops = await cards.evaluateAll((els) => {
    const row = els.filter((e) => Math.abs(e.getBoundingClientRect().top - els[0].getBoundingClientRect().top) < 2);
    const top = (e, s) => Math.round(e.querySelector(s).getBoundingClientRect().top);
    return ["product-brand", "product-title", "add-button"].map((c) => new Set(row.map((e) => top(e, "." + c))).size);
  });
  expect(tops).toEqual([1, 1, 1]);
});

// Quick to cycle (owner, 2026-11-09: "it takes a while for the images to
// show"): pointing at a photo asks for the product's photos and downloads the
// next one before any click.
test("pointing at a card's photo fetches its next photo ahead of a click", async ({ page }) => {
  const card = await cardWithPhotos(page);
  await card.scrollIntoViewIfNeeded();
  const list = page.waitForRequest(/\/api\/products\//);
  const photo = page.waitForRequest((r) => r.resourceType() === "image" && /[?&]width=(500|900)/.test(r.url()) && !r.url().includes("mark.svg"));
  await card.locator(".product-art").hover();
  await list;
  await photo;
});

// Three across beside the filter column on a wide window (owner, 2026-11-09:
// "can we show 3 columns instead of 4").
test("a brand page grid is three across on a wide window", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto("/b/fear-of-god");
  const cards = page.locator(".product-grid .product-card");
  await expect(cards.nth(3)).toBeVisible({ timeout: 60000 });
  const perRow = await cards.evaluateAll((els) => els.filter((e) => Math.abs(e.getBoundingClientRect().top - els[0].getBoundingClientRect().top) < 2).length);
  expect(perRow).toBe(3);
});

test("two quick clicks move two photos", async ({ page }) => {
  const card = await cardWithPhotos(page);
  await card.locator(".product-art").hover();
  await expect(card.locator(".card-photo-count")).toHaveText(/^1\/\d+$/);
  const next = card.getByRole("button", { name: /^Next photo of / });
  await next.click();
  await next.click();
  await expect(card.locator(".card-photo-count")).toHaveText(/^3\/\d+$/);
});
