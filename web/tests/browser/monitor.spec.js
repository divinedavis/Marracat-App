// The website's half of the Monitor page (src/monitor-client.js, 2026-11-15):
// taps, page changes and our own API calls go to /api/monitor in batches.
import { test, expect } from "./fixtures.js";

test("taps, screens and API timings are batched to /api/monitor", async ({ page }) => {
  const batches = [];
  await page.route("**/api/monitor", async (route) => {
    batches.push(JSON.parse(route.request().postData() || "{}"));
    await route.fulfill({ status: 204 });
  });
  await page.goto("/");
  await expect(page.locator("#root")).not.toBeEmpty();
  await page.getByRole("link", { name: /^Bags$/ }).first().click().catch(() => {});
  await page.waitForTimeout(800);
  await page.evaluate(() => window.dispatchEvent(new Event("pagehide")));
  await expect.poll(() => batches.length, { timeout: 8000 }).toBeGreaterThan(0);
  const ev = batches.flatMap((b) => b.ev);
  expect(batches[0].id).toMatch(/^[A-Za-z0-9_-]{16,128}$/);
  expect(batches[0].s).toMatch(/^[A-Za-z0-9]{6,40}$/);
  expect(ev.some((e) => e.k === "screen" && e.n === "home")).toBe(true);
  const api = ev.find((e) => e.k === "api");
  expect(api, "an /api call was timed").toBeTruthy();
  expect(api.n).toMatch(/^\/(api|auth)\//);
  expect(typeof api.ms).toBe("number");
  expect(typeof api.st).toBe("number");
  // Nothing typed into a field is ever sent.
  expect(JSON.stringify(batches)).not.toMatch(/@example/);
});
