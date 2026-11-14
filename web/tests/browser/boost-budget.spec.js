import { test, expect } from "./fixtures.js";

// The monthly boost budget panel on Brand ads (owner, 2026-10-10). The
// session, the brand list and every budget call are routed, so no Stripe call
// or real account is involved; the server's own checks are in
// tests/boost-budgets.test.js.
const BRAND = { brand: { id: "telfar", name: "Telfar" }, campaign: null, card: null, cardProblem: null, test: false,
  stats: { views: 0, taps: 0, spentCents: 0, todayCents: 0, owedCents: 0 } };
const OPTIONS = [
  { tier: 5, label: "Spark", days: 1, places: ["lift"], min: 5, max: 155 },
  { tier: 20, label: "Boost", days: 3, places: ["picks"], min: 20, max: 220 },
  { tier: 50, label: "Big boost", days: 7, places: ["picks", "lift"], min: 50, max: 250 },
  { tier: 100, label: "Spotlight", days: 7, places: ["premier", "picks", "lift"], min: 100, max: 500 },
];
const PLAN = { id: "bud_1", status: "active", test: false, target: "brand:telfar", tier: 100, label: "Spotlight", monthly: 400,
  nextCharge: Date.UTC(2026, 10, 10), paid: 400, spent: 100, left: 300, spentLast30: 100, running: { tier: 100, amount_cents: 10000, starts: Date.now() - 1e8, ends: Date.now() + 4e8 },
  runs: [], views: 1234, taps: 56 };

async function brandAds(page, plan) {
  await page.route("**/auth/session", (r) => r.fulfill({ json: { user: { id: "u1", name: "Brand", email: "team@telfar.net" } } }));
  await page.route("**/api/ads/brands", (r) => r.fulfill({ json: { brands: [BRAND] } }));
  await page.route("**/api/ads/admin/campaigns", (r) => r.fulfill({ status: 403, json: {} }));
  await page.route("**/api/boost-budgets/options", (r) => r.fulfill({ json: OPTIONS }));
  await page.route(/\/api\/boost-budgets\?brand=/, (r) => r.fulfill({ json: { plan } }));
  await page.goto("/brand-ads?brand=telfar");
  await expect(page.locator('[data-section="boost-budget"]')).toBeVisible({ timeout: 60000 });
}

test("a brand without a plan picks a boost and a monthly amount and goes to Checkout", async ({ page }) => {
  let sent = null;
  await page.route("**/api/boost-budgets/checkout", async (r) => {
    sent = r.request().postDataJSON();
    await r.fulfill({ status: 201, json: { url: "/brand-ads?brand=telfar&went=checkout" } });
  });
  await brandAds(page, null);
  const panel = page.locator('[data-section="boost-budget"]');
  await expect(panel).toContainText("Monthly boost budget");
  await panel.locator('[data-field="budget-tier"]').selectOption("50");
  // Out of range for Big boost ($50–$250): clamped to the top.
  await expect(panel.locator('[data-field="budget-dollars"]')).toHaveValue("250");
  await panel.locator('[data-field="budget-dollars"]').fill("150");
  await expect(panel.locator('[data-field="budget-estimate"]')).toContainText("21 days of Big boost");
  await panel.locator('[data-action="budget-start"]').click();
  await expect(page).toHaveURL(/went=checkout/);
  expect(sent).toEqual({ brand: "telfar", type: "brand", id: "telfar", tier: 50, dollars: 150 });
});

test("a running plan shows its numbers, and changes apply next month", async ({ page }) => {
  let changed = null;
  await page.route("**/api/boost-budgets/change", async (r) => {
    changed = r.request().postDataJSON();
    await r.fulfill({ json: { plan: { ...PLAN, monthly: 300 } } });
  });
  await page.route("**/api/boost-budgets/portal", (r) => r.fulfill({ json: { url: "/brand-ads?brand=telfar&went=portal" } }));
  await brandAds(page, PLAN);
  const panel = page.locator('[data-section="boost-budget"]');
  await expect(panel.locator('[data-field="budget-stats"]')).toContainText("1234");
  await expect(panel.locator('[data-field="budget-stats"]')).toContainText("left to spend");
  await expect(panel.locator('[data-field="budget-status"]')).toContainText("Spent so far");
  await panel.locator('[data-field="budget-dollars"]').fill("300");
  await panel.locator('[data-action="budget-change"]').click();
  await expect.poll(() => changed).toEqual({ brand: "telfar", tier: 100, dollars: 300 });
  await panel.locator('[data-action="budget-portal"]').click();
  await expect(page).toHaveURL(/went=portal/);
});

test("a plan whose payment failed says boosts are paused", async ({ page }) => {
  await brandAds(page, { ...PLAN, status: "past_due", running: null });
  await expect(page.locator('[data-field="budget-status"]')).toContainText("didn't go through");
});
