import { test, expect } from "./fixtures.js";
test("desktop: catalog, brands, search, variant, cart persistence, saved items", async ({
  page,
}) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: /Your next favorite/ }),
  ).toBeVisible({ timeout: 30000 });
  // The hero is drawn from /api/home, then again when the full catalog lands;
  // a decode() caught by that redraw rejects, so ask again (it failed one run
  // in three against a local server, where the catalog lands at that moment).
  for (let i = 0; ; i++) {
    try {
      await page.locator(".hero-main img").evaluate((img) => img.decode());
      break;
    } catch (e) {
      if (i === 3) throw e;
      await page.waitForTimeout(300);
    }
  }
  await page.screenshot({
    path: "test-results/home-desktop.png",
    fullPage: true,
  });
  await page.getByRole("link", { name: "All brands", exact: true }).click();
  // Every brand in the catalog, however many that is today. A fixed count went
  // stale the day the catalog grew and hid the rest of this test behind it.
  const brandCount = await page.evaluate(async () =>
    (await (await fetch("/api/catalog?v=3")).json()).brands.length,
  );
  await expect(page.locator(".all-brands .brand-card")).toHaveCount(brandCount);
  // A misspelling still finds the brand, first. (Topicals, used here before,
  // left the catalog.)
  await page.getByRole("textbox", { name: "Find a brand" }).fill("telfr");
  // Telfar first, though not alone: Kemi Telford's "telfo" is one letter
  // away too (live from 2026-10-31).
  await expect(page.locator(".all-brands .brand-card").first()).toContainText("Telfar");
  await page.locator(".all-brands .brand-card").first().click();
  await expect(
    page.getByRole("link", { name: "Website" }),
  ).toHaveAttribute("href", "https://shop.telfar.net/");
  // Website, Share and Sale alerts as one pill, Sale alerts the black one
  // (owner, 2026-11-03).
  const actions = page.getByRole("group", { name: "Brand actions" });
  await expect(actions.locator(".brand-action")).toHaveText(["Website", "Share", "Sale alerts"]);
  await expect(actions.locator("[data-action=alert-brand]")).toHaveClass(/brand-action-main/);
  await page
    .getByRole("combobox", { name: "Search products and brands" })
    .fill("Brown Girl Jane");
  await page.getByRole("button", { name: "Search", exact: true }).click();
  await expect(page.locator(".product-card").first()).toBeVisible();
  await expect(page.locator(".product-card").first()).toContainText(
    "Brown Girl Jane",
  );
  await page.locator(".product-card .save-button").first().click();
  await page.locator(".product-title").first().click();
  await expect(page.locator(".product-detail")).toBeVisible();
  await expect(page.locator(".description")).not.toHaveText(
    "Explore the brand’s store for product details.",
  );
  await page.getByRole("button", { name: "Add to cart", exact: true }).click();
  await page.getByRole("link", { name: /Cart with/ }).click();
  await expect(page.locator(".cart-line")).toHaveCount(1);
  const perBrand = page.getByRole("link", { name: /Check out at/ });
  if (await page.locator("[data-action=checkout-all]").count()) {
    // One brand with the summary's "Check out": no second per-brand button.
    await expect(perBrand).toHaveCount(0);
    await expect(page.locator("[data-action=brand-review]")).toHaveCount(0);
  } else {
    // The brand's own cart permalink: variant and quantity, plus the currency
    // the brand prices in, which checkout links have carried since multi-currency.
    const href = await perBrand.getAttribute("href");
    expect(href).toMatch(/^https:\/\/[^/]+\/cart\/\d+:1(\?currency=[A-Z]{3})?$/);
  }
  await page.reload();
  await expect(page.locator(".cart-line")).toHaveCount(1);
  await page.getByRole("button", { name: /Increase quantity/ }).click();
  await expect(page.locator(".quantity span")).toHaveText("2");
  await page.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(
    page.getByRole("heading", { name: "Your next favorite is out there." }),
  ).toBeVisible();
  await page.goto("/#/saved");
  // Saved items draw from the full catalog (147k products), so a cold load
  // waits for it like the home heading above does; the download starts at
  // once (fast-pages.spec.js holds the page to that).
  await expect(page.locator(".product-card")).toHaveCount(1, { timeout: 30000 });
  expect(errors).toEqual([]);
});
// All brands draws right after the full catalog lands. Each card used to
// count its products by filtering all 147k, ~3 s of rendering on a Mac that
// made "All brands" miss a 5 s wait (2026-10-12).
test("All brands draws within 2 s of the full catalog arriving", async ({ page }) => {
  let landed = 0;
  page.on("requestfinished", (r) => { if (r.url().includes("/api/catalog")) landed ||= Date.now(); });
  await page.goto("/brands");
  await expect(page.locator(".brand-card").first()).toBeVisible({ timeout: 30000 });
  expect(landed).toBeGreaterThan(0);
  expect(Date.now() - landed).toBeLessThan(2000);
  await expect(page.locator(".brand-card span").first()).toHaveText(/products|Explore brand store/);
});
test("mobile: responsive navigation and accessible authentication dialog", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  await expect(page.locator(".hero-main")).toBeVisible({ timeout: 30000 });
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
  ).toBeTruthy();
  await page.screenshot({
    path: "test-results/home-mobile.png",
    fullPage: true,
  });
  await page.getByRole("button", { name: "Departments", exact: true }).click();
  await page
    .locator(".department-menu")
    .getByRole("link", { name: "Bags", exact: true })
    .click();
  // A department opens at its crawlable address, headed the way people search
  // for it (SEO, 2026-10-09).
  await expect(page).toHaveURL(/\/c\/bags$/);
  await expect(
    page.getByRole("heading", { name: "Bags from independent brands", exact: true }),
  ).toBeAttached();
  await expect(page.locator(".dept-intro")).toContainText("independent brands");
  await page.getByRole("button", { name: "Sign in Account" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Continue with Google" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Continue with Apple" }),
  ).toBeVisible();
  // A provider the server has keys for goes to its sign-in page (live:
  // Google); one it doesn't says so in the dialog (live: Apple on the web).
  const providers = (await (await page.request.get("/auth/providers")).json()) ?? {};
  const unconfigured = ["apple", "google"].find((id) => !providers[id]);
  if (unconfigured) {
    const name = unconfigured === "apple" ? "Apple" : "Google";
    await page.getByRole("button", { name: `Continue with ${name}` }).click();
    await expect(page.getByRole("alert")).toContainText(`${name} sign-in is not available yet`);
  }
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  if (providers.google) {
    // Stop at Google's door rather than loading its page.
    await page.route("https://accounts.google.com/**", (route) =>
      route.fulfill({ status: 200, contentType: "text/html", body: "<title>Google</title>" }),
    );
    await page.getByRole("button", { name: "Sign in Account" }).click();
    await page.getByRole("button", { name: "Continue with Google" }).click();
    await page.waitForURL(/^https:\/\/accounts\.google\.com\//, { timeout: 15000 });
  }
});
test("auth API provides real CSRF protection and fails invalid callbacks", async ({
  request,
}) => {
  // Every assertion names the response it read. One prod run failed on
  // 2026-10-14 and passed on rerun; nginx logged every one of this test's
  // requests that day with the expected status (200/302, no 429 or 5xx on
  // /auth in 14 days of logs), so it wasn't the 60/min /auth limiter, and
  // the old messages couldn't say what the test actually saw.
  const said = async (r) => `${r.status()} ${r.url()} ${(await r.text()).slice(0, 200)}`;
  // A local server without AUTH_GOOGLE_ID/SECRET has no Google provider to
  // exercise; live always has one.
  const providersRes = await request.get("/auth/providers");
  expect(providersRes.ok(), await said(providersRes)).toBe(true);
  const providers = (await providersRes.json()) ?? {};
  test.skip(!providers.google, "Google sign-in credentials are not configured on this server");
  const session = await request.get("/auth/session");
  expect(session.status(), await said(session)).toBe(200);
  expect(await session.json(), await said(session)).toBe(null);
  const csrf = await request.get("/auth/csrf");
  expect(csrf.status(), await said(csrf)).toBe(200);
  expect((await csrf.json()).csrfToken, await said(csrf)).toMatch(/^[a-f0-9]{64}$/);
  const callback = await request.get(
    "/auth/callback/google?code=forged&state=forged",
    { maxRedirects: 0 },
  );
  expect(callback.status(), await said(callback)).toBe(302);
  expect(callback.headers()["location"], await said(callback)).toContain("error=");
  const denied = await request.post("/auth/signin/google", {
    form: { csrfToken: "forged" },
    maxRedirects: 0,
  });
  expect(denied.status(), await said(denied)).toBe(302);
  expect(denied.headers()["location"], await said(denied)).toContain("error=");
});
