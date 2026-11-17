// Shopify's Checkout Kit on the website (src/checkoutKit.js, owner
// 2026-11-15): a Shopify brand's "Check out at …" opens the brand's checkout
// in a window over marracat.com, and the cart page stays put behind it. The
// brand's store is stubbed, so no real checkout is made.
import { test, expect } from "./fixtures.js";

test("a Shopify brand's checkout opens in Checkout Kit's window over the cart", async ({ page, context, request }) => {
  const { products } = await (await request.get("/api/query?brand=gently-soap&limit=20")).json();
  const product = products.find((p) => p.available);
  test.skip(!product, "no buyable Gently Soap product in this catalog");
  await context.route("https://gentlysoap.com/**", (route) =>
    route.fulfill({ status: 200, contentType: "text/html", body: "<title>Stub checkout</title><p>Stub checkout</p>" }));
  const sent = [];
  await page.route("**/api/events", async (route) => {
    sent.push(JSON.parse(route.request().postData() || "{}"));
    await route.fulfill({ status: 204 });
  });
  await page.goto("/p/" + encodeURIComponent(product.id));
  await page.getByRole("button", { name: /Add to cart/ }).first().click();
  await page.goto("/cart");
  await page.waitForFunction(() => !!customElements.get("shopify-checkout"), null, { timeout: 15000 });
  const link = page.locator("a", { hasText: /Check out at Gently Soap/ }).first();
  await expect(link).toHaveAttribute("href", /^https:\/\/gentlysoap\.com\/cart\/\d+:1/);
  const popupOpened = page.waitForEvent("popup");
  await link.click();
  const popup = await popupOpened;
  // Checkout Kit adds the Embedded Checkout Protocol to the link it opens.
  expect(popup.url()).toMatch(/^https:\/\/gentlysoap\.com\/cart\/\d+:1.*ec_version=/);
  await expect(page).toHaveURL(/\/cart$/);
  await expect(page.locator("shopify-checkout")).toHaveCount(1);
  // Closing the window ends the session: the tab regains focus, Checkout
  // Kit sees the window shut, and the cart keeps its item.
  await popup.close();
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await expect(page.locator("shopify-checkout")).toHaveCount(0);
  await expect(page.locator(".cart-line")).toHaveCount(1);
  expect(sent.some((e) => e.e === "checkout_abandon" && e.via === "checkout_kit")).toBe(true);
});
