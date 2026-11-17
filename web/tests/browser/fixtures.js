// Every browser journey imports `test` from here, never from @playwright/test
// (owner, 2026-10-13: the live journey suite was showing up as real visitors on
// the owner dashboard). Each context this suite opens, the default one and any
// a spec opens itself with browser.newContext / browser.newPage, answers the
// analytics posts (/api/events, /api/visit, /api/vitals, /api/monitor) locally with a 204, so a run
// against https://marracat.com never writes a visit or an event. A spec that
// checks what the page sends still routes the path on its page; page routes
// run before context routes, so it sees every post.
// tests/journey-fixture.test.js keeps every spec on this import.
import { test as base, expect, devices } from "@playwright/test";

export const ANALYTICS = /\/api\/(events|visit|vitals|monitor)(\?|$)/;

export async function blockAnalytics(context) {
  await context.route(ANALYTICS, (r) => r.fulfill({ status: 204, headers: { "x-journey-stub": "1" } }));
}

export const test = base.extend({
  browser: [async ({ browser }, use) => {
    const newContext = browser.newContext.bind(browser);
    browser.newContext = async (options) => {
      const context = await newContext(options);
      await blockAnalytics(context);
      return context;
    };
    await use(browser);
  }, { scope: "worker" }],
  context: async ({ context }, use) => {
    await blockAnalytics(context);
    await use(context);
  },
});

export { expect, devices };
