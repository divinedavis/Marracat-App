import { test, expect } from "./fixtures.js";

// "Shop this in the app" on product and brand pages, iPhone/iPad only (owner,
// 2026-10-10). /api/ios-app is routed so the test doesn't depend on Apple.
const live = { live: true, url: "https://apps.apple.com/us/app/marracat/id6810905687", appId: "6810905687", version: "1.4" };
const SAFARI = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const CHROME_IOS = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0 Mobile/15E148 Safari/604.1";

async function phone(browser, userAgent) {
  const context = await browser.newContext({ userAgent, viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await context.newPage();
  await page.route("**/api/ios-app", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(live) }));
  return { context, page };
}
async function aProduct(request) {
  const c = await (await request.get("/api/catalog?v=5")).json();
  return c.products.find((p) => p.available && p.images?.length && c.brands.find((b) => b.id === p.brand)?.shopify);
}

for (const [name, ua] of [["Safari", SAFARI], ["Chrome", CHROME_IOS]]) {
  test(`iPhone ${name}: product and brand pages offer the app, and dismissing keeps it gone`, async ({ browser, request }) => {
    const p = await aProduct(request);
    const { context, page } = await phone(browser, ua);
    await page.goto(`/p/${p.id}`);
    const prompt = page.getByTestId("app-prompt");
    await expect(prompt).toBeVisible({ timeout: 60000 });
    await expect(prompt).toContainText("Shop this in the app");
    await expect(prompt.getByRole("link", { name: "Get the app" })).toHaveAttribute("href", live.url);
    // Safari's own banner gets this product as its app-argument, which the app opens.
    expect(await page.locator('meta[name="apple-itunes-app"]').getAttribute("content"))
      .toBe(`app-id=6810905687, app-argument=https://marracat.com/p/${p.id}`);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390);
    await page.goto(`/b/${p.brand}`);
    await expect(prompt).toBeVisible({ timeout: 60000 });
    await expect(prompt).toContainText(/^Shop .+ in the app/);
    await prompt.getByRole("button", { name: "Dismiss app suggestion" }).click();
    await expect(prompt).toHaveCount(0);
    await page.goto(`/p/${p.id}`);
    await expect(page.locator(".detail-actions")).toBeVisible({ timeout: 60000 });
    await expect(page.getByTestId("app-prompt")).toHaveCount(0);
    await context.close();
  });
}

test("desktop product pages show no app suggestion", async ({ page, request }) => {
  const p = await aProduct(request);
  await page.route("**/api/ios-app", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(live) }));
  await page.goto(`/p/${p.id}`);
  await expect(page.locator(".detail-actions")).toBeVisible({ timeout: 60000 });
  await expect(page.getByTestId("app-prompt")).toHaveCount(0);
});

// One app prompt per page: on iPhone product and brand pages the in-page row
// replaces the top banner; other pages keep the banner. The product column
// must also fit the phone (a wide gallery once pushed it 15px past the edge).
test("iPhone Chrome: product and brand pages show one app prompt, and the product fits the screen", async ({ browser, request }) => {
  const p = await aProduct(request);
  const { context, page } = await phone(browser, CHROME_IOS);
  for (const url of [`/p/${p.id}`, `/b/${p.brand}`]) {
    await page.goto(url);
    await expect(page.getByTestId("app-prompt")).toBeVisible({ timeout: 60000 });
    await expect(page.getByTestId("app-banner")).toHaveCount(0);
  }
  await page.goto(`/p/${p.id}`);
  await expect(page.getByTestId("app-prompt")).toBeVisible({ timeout: 60000 });
  const right = await page.locator(".detail-info").evaluate((e) => e.getBoundingClientRect().right);
  expect(right).toBeLessThanOrEqual(390 - 12);
  await page.goto("/brands");
  await expect(page.getByTestId("app-banner")).toBeVisible({ timeout: 60000 });
  await context.close();
});
