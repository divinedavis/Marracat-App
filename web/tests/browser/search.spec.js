import { test, expect } from "./fixtures.js";
async function openSearch(page) {
  await page.goto("/");
  await expect(page.locator(".hero-main")).toBeVisible({ timeout: 30000 });
  return page.getByRole("combobox", { name: "Search products and brands" });
}
test("typing shows real suggestions, keyboard selection searches, and Escape dismisses", async ({
  page,
}) => {
  const input = await openSearch(page);
  await input.fill("laundry");
  await expect(
    page.getByRole("listbox", { name: "Search suggestions" }),
  ).toBeVisible();
  await expect(page.getByRole("option").first()).toContainText(/laundry/i);
  await expect(page.locator(".suggestion-image img").first()).toBeVisible();
  await expect(page.locator(".search-backdrop")).toBeVisible();
  // The full list, which leads with words finished from real titles (the
  // server's list, shown while the catalog loads, leads with the aisle).
  await expect(page.locator(".suggestion-kind").first()).toHaveText("Search", { timeout: 30000 });
  await input.press("ArrowDown");
  await expect(input).toHaveAttribute("aria-activedescendant", "suggestion-0");
  await expect(page.getByRole("option").first()).toHaveAttribute(
    "aria-selected",
    "true",
  );
  const term = await page
    .locator("#suggestion-0 .suggestion-title")
    .innerText();
  await input.press("Enter");
  await expect(page).toHaveURL(
    new RegExp("q=" + encodeURIComponent(term).replace(/%20/g, "\\+"), "i"),
  );
  await expect(page.getByRole("listbox")).toHaveCount(0);
  await expect(
    page.locator(".product-grid .product-card").first(),
  ).toBeVisible();
  await input.fill("skin");
  await input.press("Escape");
  await expect(page.getByRole("listbox")).toHaveCount(0);
  await expect(input).toHaveValue("skin");
  await input.press("ArrowDown");
  await expect(page.getByRole("listbox")).toBeVisible();
  await input.press("Tab");
  await input.press("Tab");
  await input.press("Tab");
  await input.fill("zzzznonexistentitemqqq");
  await expect(page.getByText("No matches yet", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Clear search" }).click();
  await expect(page.getByRole("listbox")).toHaveCount(0);
  await expect(input).toHaveValue("");
});
test("clicking products and brands navigates correctly and outside clicks dismiss", async ({
  page,
}) => {
  const input = await openSearch(page);
  await input.fill("laundry");
  const product = page
    .getByRole("option")
    .filter({ has: page.locator(".suggestion-price") })
    .first();
  const title = await product.locator(".suggestion-title").innerText();
  await product.click();
  await expect(page.locator(".detail-info h1")).toHaveText(title);
  await expect(page.getByRole("listbox")).toHaveCount(0);
  await input.fill("brown girl jane");
  await page.getByRole("option", { name: "Brown Girl Jane Brand" }).click();
  await expect(
    page.getByRole("heading", { name: "Brown Girl Jane", exact: true }),
  ).toBeVisible();
  await input.fill("laundry");
  await page.locator(".search-backdrop").click({ position: { x: 5, y: 500 } });
  await expect(page.getByRole("listbox")).toHaveCount(0);
});
test("mobile suggestions fit, support touch selection, and keep Enter search working", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const input = await openSearch(page);
  await input.fill("laundry");
  await expect(page.getByRole("listbox")).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBeTruthy();
  const panel = await page.locator(".search-panel").boundingBox();
  expect(panel.x).toBeGreaterThanOrEqual(0);
  expect(panel.x + panel.width).toBeLessThanOrEqual(390);
  expect(panel.y + panel.height).toBeLessThanOrEqual(844);
  await page.screenshot({ path: "test-results/mobile-search.png" });
  await page.locator(".search-categories a").first().click();
  // A department within a search keeps the search, so it stays a query.
  await expect(page).toHaveURL(/\/shop\?.*category=/);
  await expect(page.getByRole("listbox")).toHaveCount(0);
  await input.fill("laundry sheets");
  await input.press("Enter");
  await expect(page).toHaveURL(/q=laundry\+sheets/);
  await expect(
    page.locator(".product-grid .product-card").first(),
  ).toBeVisible();
});

test("a search with a word no product uses shows the rest instead of a dead end", async ({ page }) => {
  const input = await openSearch(page);
  await input.fill("bulk t shirts");
  await input.press("Enter");
  await expect(page.locator(".shop-top h1")).toHaveText("Results for “t shirts”", { timeout: 30000 });
  await expect(page.locator(".shop-top p")).toContainText("Showing");
  await expect(page.locator(".shop-top p")).not.toContainText("No results");
});

test("suggestions show while the catalog is still downloading (owner, 2026-11-19)", async ({ page }) => {
  // A slow connection: the full catalog never arrives during this test.
  await page.route("**/api/catalog**", () => {});
  const input = await openSearch(page);
  await input.pressSequentially("fear of god", { delay: 30 });
  await expect(page.locator(".suggestion-heading")).toHaveText("Suggestions");
  const kinds = page.locator(".suggestion-kind");
  await expect(kinds.first()).toHaveText("Brand");
  await expect(page.locator(".suggestion-price").first()).toBeVisible();
  // Arrow keys and Enter open the highlighted row.
  await input.press("ArrowDown");
  await input.press("Enter");
  await expect(page).toHaveURL(/brand=fear-of-god|\/b\/fear-of-god/);
});
