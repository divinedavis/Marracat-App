import { test, expect } from "./fixtures.js";
import { readFileSync } from "node:fs";

// Shopper filters, colourway dots and the hero photo (owner, 2026-10-10), on a
// fixture catalog so the assertions don't depend on what brands sell today.
const fixture = readFileSync(new URL("../fixtures/catalog-ai.json", import.meta.url), "utf8");
// 1x1 PNG for every fixture photo, so no card falls back to the logo.
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==", "base64");

test.beforeEach(async ({ page }) => {
  await page.route(/\/api\/(home|catalog)\b/, (route) => route.fulfill({ contentType: "application/json", body: fixture }));
  await page.route(/\/api\/query\b/, (route) => route.fulfill({ status: 503, body: "" }));
  await page.route("https://img.fixture.test/**", (route) => route.fulfill({ contentType: "image/png", body: PNG }));
});

test("hair chips filter to what the brand says, and turn off again", async ({ page }) => {
  await page.goto("/shop?category=hair");
  const cards = page.locator(".product-card");
  await expect(cards).toHaveCount(3, { timeout: 30000 });
  // In the filter column beside the grid since 2026-11-03 (three pills on top).
  const chip = page.getByRole("complementary", { name: "Filters" }).getByRole("button", { name: "For 4C hair", exact: true });
  await expect(chip).toBeVisible();
  // Only values something on the page carries are offered.
  await expect(page.getByRole("button", { name: "For 3C hair", exact: true })).toHaveCount(0);
  await chip.click();
  await expect(cards).toHaveCount(1);
  await expect(cards.first()).toContainText("Coil Cream");
  await expect(chip).toHaveAttribute("aria-pressed", "true");
  expect(page.url()).toContain("hair=4c");
  await chip.click();
  await expect(cards).toHaveCount(3);
  await page.getByRole("button", { name: "Fragrance-free", exact: true }).click();
  await expect(cards).toHaveCount(1);
});

test("a colourway is one card whose dots switch the photo and the link", async ({ page }) => {
  await page.goto("/shop?category=clothing");
  const cards = page.locator(".product-card");
  await expect(cards).toHaveCount(2, { timeout: 30000 });
  const hoodie = cards.filter({ hasText: "Classic Hoodie" });
  await expect(hoodie).toHaveCount(1);
  const dots = hoodie.locator(".color-dot");
  await expect(dots).toHaveCount(2);
  await expect(hoodie.locator("img")).toHaveAttribute("src", /hoodie-black/);
  await hoodie.getByRole("button", { name: "Sand", exact: true }).click();
  await expect(hoodie.locator("img")).toHaveAttribute("src", /hoodie-sand/);
  await expect(hoodie.locator("a.product-title")).toHaveAttribute("href", /w-sand/);
  await expect(hoodie.getByRole("button", { name: "Sand", exact: true })).toHaveAttribute("aria-pressed", "true");
  // The tee is in no group: no dots.
  await expect(cards.filter({ hasText: "Pocket Tee" }).locator(".color-dot")).toHaveCount(0);
});

test("the home hero shows the product's lifestyle photo", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(".hero-image img")).toHaveAttribute("src", /bag-worn/, { timeout: 30000 });
});

// Owner, 2026-10-24: three pills at most; everything else, colour included, in
// the filter column (2026-11-03). On phones the column is behind the Filters
// button, which counts what is switched on.
test("filters and colours sit in the filter column, counted on the phone's Filters button", async ({ page }) => {
  await page.goto("/shop?category=clothing");
  await expect(page.locator(".product-card")).toHaveCount(2, { timeout: 30000 });
  const column = page.getByRole("complementary", { name: "Filters" });
  await expect(column.locator(".color-filter")).toBeVisible();
  await column.locator(".color-chip").first().click();
  expect(page.url()).toContain("color=");
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(column).toBeHidden();
  const button = page.getByRole("button", { name: /^Filters/ });
  await expect(button).toHaveAttribute("aria-expanded", "false");
  await expect(page.locator(".filters-count")).toHaveText("1");
  await button.click();
  await expect(column.locator(".color-filter")).toBeVisible();
  await column.getByRole("button", { name: "Clear all" }).click();
  await expect(page.locator(".filters-count")).toHaveCount(0);
  expect(page.url()).not.toContain("color=");
});
