import { test, expect } from "./fixtures.js";

// Typing the street in the checkout details form suggests addresses from
// Apple Maps; picking one fills city, state and ZIP (owner, 2026-10-04).
test("desktop: the details form suggests addresses and fills the rest", async ({ page }) => {
  // Without MAPKIT_KEY_ID/MAPKIT_PRIVATE_KEY_PATH the token route answers 404
  // and the form stays a plain form (a local server); live has the key.
  const token = await page.request.get("/api/mapkit-token");
  test.skip(token.status() === 404, "MapKit JS credentials are not configured on this server");
  const blocked = [];
  page.on("console", (m) => /Content Security Policy|Refused to/.test(m.text()) && blocked.push(m.text()));
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const id = await page.evaluate(async () => {
    const { brands, products } = await (await fetch("/api/catalog?v=3")).json();
    const ucp = new Set(brands.filter((b) => b.ucp).map((b) => b.id));
    return products.find((p) => ucp.has(p.brand) && p.available && p.variants?.some((v) => v.available)).id;
  });
  await page.goto("/#/product?id=" + encodeURIComponent(id));
  await page.getByRole("button", { name: /Add to cart/ }).first().click();
  await page.goto("/#/cart");
  await page.locator("[data-action=checkout-all]").click();
  const street = page.locator('[data-field="street"]');
  await expect(street).toBeVisible({ timeout: 10000 });
  await street.pressSequentially("1600 Pennsylvania Ave NW Wash", { delay: 40 });
  const first = page.locator("[data-action=address-suggestion]").first();
  await expect(first, "no suggestion; blocked: " + blocked.join(" | ")).toBeVisible({ timeout: 15000 });
  await first.click();
  await expect(page.locator('[data-field="region"]')).toHaveValue("DC", { timeout: 10000 });
  await expect(page.locator('[data-field="postalCode"]')).not.toHaveValue("");
  await expect(page.locator('[data-field="city"]')).not.toHaveValue("");
  expect(blocked, blocked.join("\n")).toEqual([]);
});
