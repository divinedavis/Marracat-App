import { test, expect } from "./fixtures.js";

/// The banner is driven by /api/ios-app, which asks Apple whether the listing
/// is actually live. Both answers are exercised here with a routed response,
/// because the real one flips the day the app goes back on sale.
const live = {
  live: true,
  url: "https://apps.apple.com/us/app/marracat/id6810905687",
  appId: "6810905687",
  version: "1.0",
};

async function answer(page, body) {
  await page.route("**/api/ios-app", (route) =>
    route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(body) }),
  );
}

test("desktop shows the QR code and no App Store button", async ({ page, request }) => {
  await answer(page, live);
  await page.goto("/");
  const banner = page.getByTestId("app-banner");
  await expect(banner).toBeVisible({ timeout: 30000 });
  await expect(banner.getByRole("link")).toHaveCount(0);
  const qr = banner.locator("img[src='/app-qr.svg?v=2']");
  await expect(qr).toBeVisible();
  // What the code encodes: marracat.com/app, a page (shareable preview, Apple's
  // Smart App Banner) that sends a phone without the app on to the App Store.
  const app = await request.get("/app", { maxRedirects: 0 });
  expect(app.status()).toBe(200);
  const html = await app.text();
  expect(html).toContain('name="apple-itunes-app"');
  expect(html).toMatch(/href="https:\/\/apps\.apple\.com\/us\/app\/marracat\/id\d+"/);
  await page.screenshot({ path: "test-results/app-banner-desktop.png" });
});

test("an app that is off sale gets no banner at all", async ({ page }) => {
  await answer(page, { live: false, url: live.url, appId: live.appId, version: null });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 30000 });
  await expect(page.getByTestId("app-banner")).toHaveCount(0);
});

test("dismissing the banner keeps it gone on the next visit", async ({ page }) => {
  await answer(page, live);
  await page.goto("/");
  const banner = page.getByTestId("app-banner");
  await expect(banner).toBeVisible({ timeout: 30000 });
  await banner.getByRole("button", { name: "Dismiss" }).click();
  await expect(banner).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 30000 });
  await expect(page.getByTestId("app-banner")).toHaveCount(0);
});

test("iPhone Safari gets only Apple's own banner; other iPhone browsers get ours", async ({ browser }) => {
  const safari = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    viewport: { width: 390, height: 844 },
  });
  let page = await safari.newPage();
  await answer(page, live);
  await page.goto("/");
  await expect(page.getByRole("heading", { name: /Your next favorite/ })).toBeVisible({ timeout: 30000 });
  await expect(page.getByTestId("app-banner")).toHaveCount(0);
  await safari.close();
  const chrome = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0 Mobile/15E148 Safari/604.1",
    viewport: { width: 390, height: 844 },
  });
  page = await chrome.newPage();
  await answer(page, live);
  await page.goto("/");
  const banner = page.getByTestId("app-banner");
  await expect(banner).toBeVisible({ timeout: 30000 });
  await expect(banner.getByRole("link", { name: "Get the app" })).toHaveAttribute("href", live.url);
  await page.screenshot({ path: "test-results/app-banner-iphone.png" });
  await chrome.close();
});
