import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { createHmac } from "node:crypto";
import { installBoostSchema, activeBoosts, tierFor, targetKey, verifyStripeSignature } from "../server/boosts.js";

const lookup = {
  productRecord: (id) => ({ p1: { id: "p1", brand: "b1", available: true }, p2: { id: "p2", brand: "b2", available: false } })[id],
  brandRecord: (id) => ({ b1: { id: "b1" }, b2: { id: "b2" }, b3: { id: "b3" }, b4: { id: "b4" }, b5: { id: "b5" } })[id],
};
const NOW = Date.UTC(2026, 9, 4, 18);
function db(boosts) {
  const d = new Database(":memory:");
  installBoostSchema(d);
  boosts.forEach(([target, tier, starts = NOW - 1000, ends = NOW + 86400e3], i) =>
    d.prepare("INSERT INTO boosts(id,target,tier,amount_cents,status,created,starts,ends) VALUES(?,?,?,?,'paid',?,?,?)")
      .run("x" + i, target, tier, tier * 100, NOW, starts, ends));
  return d;
}

test("a running total reaches the highest tier it covers", () => {
  assert.equal(tierFor(500), 5);
  assert.equal(tierFor(1999), 5);
  assert.equal(tierFor(10000), 100);
  assert.equal(tierFor(400), 0);
});

test("five $20 boosts for one brand put it in the carousel", () => {
  const a = activeBoosts(db(Array.from({ length: 5 }, () => ["brand:b1", 20])), NOW, lookup);
  assert.deepEqual(a.premier, ["brand:b1"]);
  assert.ok(a.picks.includes("brand:b1") && a.lift.includes("brand:b1"));
});

test("tiers place where they should; expired and unpaid don't count", () => {
  const d = db([["brand:b1", 5], ["brand:b3", 20], ["brand:b4", 50], ["brand:b5", 100, NOW - 9e8, NOW - 1]]);
  d.prepare("INSERT INTO boosts(id,target,tier,amount_cents,status,created) VALUES('pend','brand:b2',100,10000,'pending',?)").run(NOW);
  const a = activeBoosts(d, NOW, lookup);
  assert.deepEqual(a.premier, []);
  assert.deepEqual(a.picks.sort(), ["brand:b3", "brand:b4"]);
  assert.deepEqual(a.lift.sort(), ["brand:b1", "brand:b4"]);
  assert.equal(a.label, "Sponsored");
});

test("only three Spotlights at once, biggest first; a sold-out product shows its brand", () => {
  const a = activeBoosts(db([["brand:b1", 100], ["brand:b1", 100], ["brand:b3", 100], ["brand:b4", 100], ["brand:b5", 100], ["product:p2", 20]]), NOW, lookup);
  assert.equal(a.premier.length, 3);
  assert.equal(a.premier[0], "brand:b1");
  assert.ok(a.picks.includes("brand:b2"), "p2 is sold out, so its brand b2 is boosted");
});

test("test-mode boosts never show publicly, only in the owner's preview", () => {
  const d = db([["brand:b1", 100]]);
  d.prepare("UPDATE boosts SET live=0").run();
  assert.deepEqual(activeBoosts(d, NOW, lookup).premier, []);
  assert.deepEqual(activeBoosts(d, NOW, lookup, 0, { includeTest: true }).premier, ["brand:b1"]);
});

test("targets must be on Marracat", () => {
  assert.equal(targetKey("product", "p1", lookup), "product:p1");
  assert.equal(targetKey("brand", "nope", lookup), null);
  assert.equal(targetKey("user", "p1", lookup), null);
});

test("Stripe signatures: right secret and fresh timestamp only", () => {
  const raw = '{"type":"checkout.session.completed"}', secret = "whsec_test", t = Math.floor(NOW / 1000);
  const sig = createHmac("sha256", secret).update(`${t}.${raw}`).digest("hex");
  assert.equal(verifyStripeSignature(raw, `t=${t},v1=${sig}`, secret, NOW), true);
  assert.equal(verifyStripeSignature(raw, `t=${t},v1=${sig}`, "whsec_other", NOW), false);
  assert.equal(verifyStripeSignature(raw + " ", `t=${t},v1=${sig}`, secret, NOW), false);
  assert.equal(verifyStripeSignature(raw, `t=${t},v1=${sig}`, secret, NOW + 600e3), false, "older than five minutes");
});

// Audit 2026-10-07 (L1): boost views/taps count once per IP per day, not per
// client-chosen id.
test("boost events from one IP with many made-up ids count once", async () => {
  const express = (await import("express")).default;
  const { boostRoutes } = await import("../server/boosts.js");
  const d = db([["brand:b1", 20]]);
  const app = express();
  app.set("trust proxy", "loopback");
  boostRoutes(app, d, { env: {}, now: () => NOW });
  const s = app.listen(0, "127.0.0.1"); await new Promise((r) => s.once("listening", r));
  const send = (id, ip) => fetch(`http://127.0.0.1:${s.address().port}/api/boosts/events`, { method: "POST",
    headers: { "Content-Type": "application/json", "X-Marracat-Device": id, "X-Forwarded-For": ip },
    body: JSON.stringify({ events: [{ target: "brand:b1", kind: "view" }] }) });
  try {
    for (let i = 0; i < 5; i++) assert.equal((await send("visitor-id-number-" + i, "203.0.113.5")).status, 204);
    await send("visitor-id-number-x", "198.51.100.7");
    assert.equal(d.prepare("SELECT COUNT(*) AS n FROM boost_events WHERE kind='view'").get().n, 2);
  } finally { s.close(); }
});
