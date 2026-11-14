import { test } from "node:test";
import assert from "node:assert/strict";
import { fxRoutes } from "../server/fx-rates.js";

function harness(fetcher, clock = { t: 0 }) {
  let handler;
  fxRoutes({ get: (_p, h) => (handler = h) }, { fetcher, now: () => clock.t });
  const call = async () => {
    let body;
    await handler({}, { set() {}, json: (b) => (body = b) });
    return body;
  };
  return { call, clock };
}
const ok = (rates) => async () => ({ ok: true, json: async () => ({ date: "2026-09-30", rates }) });

test("dollar rates come from the ECB answer and are cached for 12 hours", async () => {
  let calls = 0;
  const all = { GBP: 0.8, EUR: 0.9, SEK: 10, ZAR: 16, NGN: 1300, KES: 130, GHS: 12 };
  const { call, clock } = harness(async (...a) => (calls++, ok(all)(...a)));
  const first = await call();
  assert.equal(first.usd.GBP, 1.25);
  assert.ok(Math.abs(first.usd.EUR - 1 / 0.9) < 1e-9);
  assert.equal(calls, 2, "one refresh asks both sources");
  clock.t = 11 * 3600e3;
  await call();
  assert.equal(calls, 2);
  clock.t = 13 * 3600e3;
  await call();
  assert.equal(calls, 4);
});
test("the ECB rates come from Frankfurter and NGN, KES and GHS from ExchangeRate-API", async () => {
  const urls = [];
  const { call } = harness(async (url) => {
    urls.push(url);
    return ok(url.includes("frankfurter") ? { GBP: 0.8, EUR: 0.9, SEK: 10, ZAR: 16 } : { NGN: 1300, KES: 130, GHS: 12, GBP: 5 })();
  });
  const body = await call();
  assert.equal(urls.length, 2);
  assert.equal(body.usd.ZAR, 1 / 16);
  assert.equal(body.usd.NGN, 1 / 1300);
  assert.equal(body.usd.GBP, 1.25, "the ECB's pound wins over the open endpoint's");
});
test("a failed or absurd answer keeps the last good rates", async () => {
  let answer = ok({ GBP: 0.8, EUR: 0.9 });
  const { call, clock } = harness((...a) => answer(...a));
  await call();
  answer = ok({ GBP: 80, EUR: 0.9 });
  clock.t = 13 * 3600e3;
  assert.equal((await call()).usd.GBP, 1.25);
  answer = async () => { throw new Error("offline"); };
  clock.t = 30 * 3600e3;
  assert.equal((await call()).usd.GBP, 1.25);
});
test("a server that never reached the ECB serves the built-in fallback", async () => {
  const { call } = harness(async () => ({ ok: false, status: 503 }));
  const body = await call();
  assert.equal(body.fallback, true);
  assert.ok(body.usd.GBP > 1 && body.usd.EUR > 1);
  assert.ok(body.usd.NGN > 0 && body.usd.NGN < 0.01, "₦ is worth well under a cent");
});
