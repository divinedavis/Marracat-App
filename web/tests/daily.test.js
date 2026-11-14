import { test } from "node:test";
import assert from "node:assert/strict";
import { dayNumber, daily, rotateDaily, HERO_BRANDS, BEAUTY_BRANDS, HOME_BRANDS } from "../src/daily.js";

test("the day turns over at midnight in New York, not UTC", () => {
  const lateEvening = new Date("2026-10-09T23:30:00-04:00"); // 03:30 UTC on the 10th
  const justAfter = new Date("2026-10-10T00:05:00-04:00");
  assert.equal(dayNumber(justAfter) - dayNumber(lateEvening), 1);
  assert.equal(dayNumber(new Date("2026-10-10T03:30:00Z")), dayNumber(lateEvening), "same NY day despite the UTC date");
});

test("today's pick changes daily and tiles differ on the same day", () => {
  const pool = ["a", "b", "c", "d"];
  assert.notEqual(daily(pool, 0, 100), daily(pool, 0, 101));
  assert.notEqual(daily(pool, 0, 100), daily(pool, 1, 100));
  assert.equal(daily([], 0, 100), undefined);
});

test("a rotated row keeps every item, starting somewhere new each day", () => {
  const list = ["a", "b", "c", "d", "e"];
  const r = rotateDaily(list, 0, 3);
  assert.deepEqual([...r].sort(), list);
  assert.notDeepEqual(rotateDaily(list, 0, 3), rotateDaily(list, 0, 4));
});

test("the hand-picked pools don't overlap", () => {
  const all = [...HERO_BRANDS, ...BEAUTY_BRANDS, ...HOME_BRANDS];
  assert.equal(new Set(all).size, all.length);
});

test("a pool as long as the step still changes every day (the 7-brand bag tile showed one brand daily)", () => {
  const pool = ["a", "b", "c", "d", "e", "f", "g"];
  const firsts = new Set([0, 1, 2, 3, 4, 5, 6].map((d) => rotateDaily(pool, 0, 100 + d)[0]));
  assert.equal(firsts.size, 7);
});

test("RIPL EFEK is in the Home & living tile's pool (premier brand, owner 2026-10-10)", () => {
  assert.ok(HOME_BRANDS.includes("ripl-efek"));
});
