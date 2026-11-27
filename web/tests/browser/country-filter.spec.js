import { test, expect } from "./fixtures.js";

// Owner, 2026-11-26: "Let's put a filter for the country the company is
// founded". The filter column lists the countries brands are based in.
// A search says "7,155 products to discover" under its heading.
const count = async (page) => Number((await page.locator(".shop-top p").first().innerText()).replace(/[^0-9]/g, ""));

test("the Country filter keeps one country's brands and All puts the rest back", async ({ page }) => {
  await page.goto("/#/shop?q=dress");
  await expect(page.locator(".product-card").first()).toBeVisible({ timeout: 30000 });
  const group = page.getByRole("group", { name: "Filter by the brand's country" });
  // Phones keep the filter column behind the Filters button.
  if (!(await group.isVisible())) await page.getByRole("button", { name: /^Filters/ }).first().click();
  await expect(group).toBeVisible();
  // Countries are named in full, each with how many products it has.
  await expect(group.getByRole("radio", { name: /United States/ })).toBeVisible();
  const before = await count(page);
  await group.getByRole("radio", { name: /Nigeria/ }).check();
  await expect.poll(() => count(page)).toBeLessThan(before);
  expect(await count(page)).toBeGreaterThan(0);
  await expect(page.locator(".product-card").first()).toBeVisible();
  await group.getByRole("radio", { name: "All" }).check();
  await expect.poll(() => count(page)).toBe(before);
});
