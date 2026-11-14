import { test, expect } from "./fixtures.js";

// Brand pages have no aisle chips; product types in the filter column narrow
// them instead (owner, 2026-10-09: "i want to filter on sweatpants"; a column
// beside the grid since 2026-11-03).
test("a brand page filters by product type and can go back to all types", async ({ page }) => {
  await page.goto("/b/fear-of-god");
  const types = page.getByRole("group", { name: "Filter by product type" });
  await expect(types).toBeVisible({ timeout: 60000 });
  const all = types.getByRole("radio", { name: "All", exact: true });
  await expect(all).toBeChecked();
  const shown = await types.getByRole("radio").count();
  const sweats = types.getByRole("radio", { name: /^Sweatpants/ });
  const pick = (await sweats.count()) ? sweats : types.getByRole("radio").nth(1);
  await pick.check();
  const cards = page.locator(".product-card");
  await expect(cards.first()).toBeVisible();
  if (await sweats.count()) await expect(cards.first()).toContainText(/sweat|jogger|track/i);
  // Picking a type keeps the other types on offer, and a count beside each.
  expect(await types.getByRole("radio").count()).toBe(shown);
  await expect(types.locator(".filter-option small").first()).toHaveText(/^\d[\d,]*$/);
  // "Show all" lists every type; then back to all of them.
  const more = types.getByRole("button", { name: /^Show all \d+ types$/ });
  if (await more.count()) {
    await more.click();
    expect(await types.getByRole("radio").count()).toBeGreaterThan(shown);
  }
  await all.check();
  await expect(all).toBeChecked();
});

// Phones: Filters and Sort buttons; Filters opens the column as a sheet.
test("on a phone the filters open as a sheet and Clear all resets them", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/b/fear-of-god");
  const open = page.getByRole("button", { name: "Filters" });
  await expect(open).toBeVisible({ timeout: 60000 });
  await expect(page.getByRole("combobox", { name: "Sort products" })).toBeVisible();
  const sheet = page.getByRole("complementary", { name: "Filters" });
  await expect(sheet).toBeHidden();
  await open.click();
  await expect(sheet).toBeVisible();
  await sheet.getByRole("checkbox", { name: "In stock only" }).check();
  await sheet.getByRole("button", { name: /^Show [\d,]+ products?$/ }).click();
  await expect(sheet).toBeHidden();
  await expect(page.locator(".filters-count")).toHaveText("1");
  await open.click();
  await sheet.getByRole("button", { name: "Clear all" }).click();
  await expect(sheet.getByRole("checkbox", { name: "In stock only" })).not.toBeChecked();
  await page.keyboard.press("Escape");
  await expect(sheet).toBeHidden();
  await expect(page.locator(".filters-count")).toHaveCount(0);
});
