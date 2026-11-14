import { test, expect } from "./fixtures.js";

// Owner, 2026-11-08, on marracat.com in Safari:
// 1. "when i click pants in the explore in section nothing happens"
// 2. "the entire sort button should be clickable"
// 3. "instead of another currency being the leading price, it should be in usd
//    by default - lets have a filter or a currency converter button too"

// Safari doesn't focus a link on click, so pressing an "Explore in" link blurred
// the search box, the panel closed and the link was gone before its click. The
// suite runs Chrome (which focuses the link), so the check is the cause itself:
// the press must not take focus from the search box.
test("an Explore in link keeps the search box focused through the press and opens the department", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const input = page.getByLabel("Search products and brands");
  await input.click();
  await input.fill("pants");
  const chip = page.locator(".search-categories a").first();
  await expect(chip).toBeVisible({ timeout: 60000 });
  const prevented = await chip.evaluate((a) => {
    const press = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
    a.dispatchEvent(press);
    return press.defaultPrevented;
  });
  expect(prevented).toBe(true);
  await chip.click();
  await expect(page).toHaveURL(/\/shop\?.*category=/);
});

// The sort menu used to open only from the words inside the pill; the select
// now lies over the whole pill, so its icon end opens it too.
test("the whole sort pill opens the sort menu", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/b/fear-of-god");
  const select = page.getByRole("combobox", { name: "Sort products" });
  await expect(select).toBeAttached({ timeout: 60000 });
  const pill = page.locator(".sort-control:not(.currency-control)");
  const box = await pill.boundingBox();
  for (const x of [box.x + 8, box.x + box.width / 2, box.x + box.width - 8]) {
    const hit = await page.evaluate(([px, py]) => document.elementFromPoint(px, py)?.getAttribute("aria-label"), [x, box.y + box.height / 2]);
    expect(hit, `click at x=${Math.round(x - box.x)} in the pill`).toBe("Sort products");
  }
  await select.selectOption("low");
  await expect(pill.locator(".sort-long")).toHaveText("Price: low to high");
});

// A brand that charges in another currency leads with dollars, the real price
// beside it; the Currency picker switches every price and is remembered.
test("prices lead with dollars, and the currency picker switches them", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  const found = await page.evaluate(async () => {
    const [{ brands, products }, rates] = await Promise.all([
      fetch("/api/catalog?v=3").then((r) => r.json()),
      fetch("/api/rates").then((r) => (r.ok ? r.json() : null)),
    ]);
    const known = new Set(Object.keys(rates?.usd || {}));
    const p = products.find((x) => x.currency && x.currency !== "USD" && known.has(x.currency) && x.price > 0);
    return p && { brand: p.brand, currency: p.currency, live: !!brands.find((b) => b.id === p.brand) };
  });
  test.skip(!found?.live, "no brand charging in a currency /api/rates knows on this server");
  await page.goto("/b/" + encodeURIComponent(found.brand));
  const price = page.locator(".product-card .price").first();
  await expect(price).toContainText("$", { timeout: 60000 });
  await expect(price).toHaveText(/^\$[\d,]+\.\d\d \(.+\)/);
  const picker = page.getByRole("combobox", { name: "Show prices in" });
  await expect(picker).toHaveValue("USD");

  await picker.selectOption("ORIGINAL");
  await expect(price).not.toHaveText(/^\$/);
  await expect(price.locator(".fx-approx")).toContainText("≈ $");
  await page.reload();
  await expect(page.getByRole("combobox", { name: "Show prices in" })).toHaveValue("ORIGINAL", { timeout: 60000 });

  await page.getByRole("combobox", { name: "Show prices in" }).selectOption("USD");
  await expect(price).toHaveText(/^\$/);
  expect(await page.evaluate(() => localStorage.getItem("marracat-currency"))).toBeNull();
});
