import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { liveCovers } from "../server/live-cover.js";
import { installLiveActivitySchema, stepAlert } from "../server/live-activity.js";

// 2026-10-17 15:00 UTC = 11 am in New York; 03:00 UTC = 11 pm the day before.
const ELEVEN_AM = Date.parse("2026-10-17T15:00:00Z");
const ELEVEN_PM = Date.parse("2026-10-17T03:00:00Z");

function db(fields = {}) {
  const d = new Database(":memory:");
  d.exec("CREATE TABLE restock_devices (hash TEXT PRIMARY KEY, token TEXT, environment TEXT, updated INTEGER NOT NULL, tz TEXT)");
  d.prepare("INSERT INTO restock_devices VALUES('dev','t','production',0,'America/New_York')").run();
  installLiveActivitySchema(d);
  installLiveActivitySchema(d); // the column migration runs twice safely
  const row = { device: "dev", start_token: "ab", enabled: 1, updated: 0, ...fields };
  const cols = Object.keys(row);
  d.prepare(`INSERT INTO live_activities(${cols.join(",")}) VALUES(${cols.map((c) => "@" + c).join(",")})`).run(row);
  return d;
}

test("one notification, not two: a phone that takes Live Activities gets the card's alert instead", () => {
  // No card yet: out for delivery starts one (with its own alert) at any hour.
  assert.equal(liveCovers(db(), "dev", "out_for_delivery", ELEVEN_PM), true);
  // "Arriving today" only in the day's window.
  assert.equal(liveCovers(db(), "dev", "arriving_today", ELEVEN_AM), true);
  assert.equal(liveCovers(db(), "dev", "arriving_today", ELEVEN_PM), false);
  // Delivered with no card on screen would go unsaid: ordinary notification.
  assert.equal(liveCovers(db(), "dev", "delivered", ELEVEN_AM), false);
  // With a card on screen, delivered is the card's to say.
  const running = { state: "{}", started: ELEVEN_AM - 3600_000 };
  assert.equal(liveCovers(db(running), "dev", "delivered", ELEVEN_AM), true);
  // A card past Apple's 8 hours is gone.
  assert.equal(liveCovers(db({ ...running, started: ELEVEN_AM - 9 * 3600_000 }), "dev", "delivered", ELEVEN_AM), false);
  // Shipped and reschedules are always ordinary.
  for (const step of ["shipped", "rescheduled"]) assert.equal(liveCovers(db(running), "dev", step, ELEVEN_AM), false, step);
});

test("a delivery problem is the card's to say when the card shows that brand's order (owner, 2026-10-21)", () => {
  const state = JSON.stringify({ orders: [{ id: "t7", brand: "Bask & Lather Co.", item: "Beard Growth Magic", status: "problem" }], index: 0 });
  const running = { state, started: ELEVEN_AM - 3600_000 };
  assert.equal(liveCovers(db(running), "dev", "problem", ELEVEN_AM, { brand: "Bask & Lather Co." }), true, "one notification, the card's");
  assert.equal(liveCovers(db(running), "dev", "problem", ELEVEN_AM, { brand: "KOBA" }), false, "an order the card doesn't show is still told");
  assert.equal(liveCovers(db(running), "dev", "problem", ELEVEN_AM), false, "no brand given: told");
  assert.equal(liveCovers(db(), "dev", "problem", ELEVEN_AM, { brand: "Bask & Lather Co." }), false, "no card on screen: told");
  assert.equal(liveCovers(db({ ...running, started: ELEVEN_AM - 9 * 3600_000 }), "dev", "problem", ELEVEN_AM, { brand: "Bask & Lather Co." }), false,
    "a card past Apple's 8 hours is gone");
});

test("no card possible means the ordinary notification goes", () => {
  assert.equal(liveCovers(db({ enabled: 0 }), "dev", "out_for_delivery", ELEVEN_AM), false, "off in the app");
  assert.equal(liveCovers(db({ authorized: 0 }), "dev", "out_for_delivery", ELEVEN_AM), false, "off in iOS Settings");
  assert.equal(liveCovers(db({ start_token: null }), "dev", "out_for_delivery", ELEVEN_AM), false, "no start token");
  assert.equal(liveCovers(db({ dismissed_day: "2026-10-17" }), "dev", "out_for_delivery", ELEVEN_AM), false, "swiped away today");
  assert.equal(liveCovers(db({ dismissed_day: "2026-10-16" }), "dev", "out_for_delivery", ELEVEN_AM), true, "yesterday's swipe");
  assert.equal(liveCovers(db(), "other", "out_for_delivery", ELEVEN_AM), false, "unknown phone");
  assert.equal(liveCovers(new Database(":memory:"), "dev", "out_for_delivery", ELEVEN_AM), false, "no table");
});

test("the card's update carries the alert for a step change, and only then", () => {
  const prev = { orders: [{ id: "a", brand: "RIPL EFEK", item: "Detergent", status: "arriving" }], index: 0 };
  const out = { orders: [{ id: "a", brand: "RIPL EFEK", item: "Detergent", status: "out_for_delivery" }], index: 0 };
  assert.deepEqual(stepAlert(prev, out), { title: "Out for delivery", body: "RIPL EFEK · Detergent" });
  assert.equal(stepAlert(out, out), null, "nothing changed");
  const added = { orders: [...out.orders, { id: "b", brand: "KOBA", status: "delivered" }], index: 1 };
  assert.deepEqual(stepAlert(out, added), { title: "Delivered", body: "KOBA" });
  assert.equal(stepAlert(prev, { orders: [{ ...prev.orders[0], eta: "By 5 PM" }], index: 0 }), null, "an ETA change stays quiet");
});

test("a reschedule to today is the card's when it shows that brand's order (owner, 2026-10-26)", () => {
  const state = JSON.stringify({ orders: [{ id: "t19", brand: "Bask & Lather Co.", item: "Beard Growth Magic", status: "out_for_delivery" }], index: 0 });
  const running = { state, started: ELEVEN_AM - 3600_000 };
  const covers = (fields, brand, day) => liveCovers(db(fields), "dev", "rescheduled", ELEVEN_AM, { brand, day });
  assert.equal(covers(running, "Bask & Lather Co.", "2026-10-17"), true, "the card already says it's coming today");
  assert.equal(covers(running, "Bask & Lather Co.", "2026-10-19"), false, "moved to another day: told");
  assert.equal(covers(running, "KOBA", "2026-10-17"), false, "an order the card doesn't show: told");
  assert.equal(covers({}, "Bask & Lather Co.", "2026-10-17"), false, "no card on screen: told");
});
