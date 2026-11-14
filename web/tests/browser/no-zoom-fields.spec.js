import { test, expect, devices } from "./fixtures.js";

const { defaultBrowserType, ...iphone } = devices["iPhone 15 Pro"];

// iPhone Safari zooms the page into any tapped field under 16px, which
// pushed the header's search button and cart off screen (owner, 2026-10-04).
// The suite runs Chrome; the iPhone viewport, touch and user agent are what
// matter here ((pointer: coarse) is what turns the 16px rule on).
test.use(iphone);

test("phone: every text field and menu is at least 16px", async ({ page }) => {
  for (const route of ["/", "/#/shop?q=socks", "/#/brands"]) {
    await page.goto(route);
    await expect(page.getByRole("combobox", { name: "Search products and brands" })).toBeVisible({ timeout: 30000 });
    await page.waitForTimeout(1500);
    const small = await page.evaluate(() =>
      [...document.querySelectorAll('input:not([type="checkbox"]):not([type="radio"]):not([type="hidden"]), select, textarea')]
        .filter((e) => e.offsetParent && parseFloat(getComputedStyle(e).fontSize) < 16)
        .map((e) => (e.getAttribute("aria-label") || e.name || e.className) + " " + getComputedStyle(e).fontSize));
    expect(small, route).toEqual([]);
  }
});
