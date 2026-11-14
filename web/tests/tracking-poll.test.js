import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { openNumbers, trackingPoller } from "../server/tracking-poll.js";
import { installTrackingSchema, track17Update } from "../server/order-tracking.js";
import { installRelaySchema } from "../server/relay.js";
import { installRestockSchema } from "../server/restock.js";

function db() {
  const d = new Database(":memory:");
  installRestockSchema(d); installRelaySchema(d); installTrackingSchema(d);
  return d;
}
const NOW = Date.parse("2026-10-09T16:00:00Z");

test("only numbers still on their way are asked about", () => {
  const d = db();
  const ins = d.prepare("INSERT INTO relay_events(user_id,received,kind,tracker_id,tracking_status) VALUES('u',?,?,?,?)");
  ins.run(NOW - 3600e3, "shipped", "1ZOPEN", "in_transit");
  ins.run(NOW - 3600e3, "shipped", "1ZDONE", "delivered");
  ins.run(NOW - 90 * 86400e3, "shipped", "1ZOLD", "in_transit");
  d.prepare("INSERT INTO tracked_orders(device,brand_id,checkout_id,tracker_id,created,done) VALUES('d','b','c1','9400OPEN',?,NULL),('d','b','c2','9400CLOSED',?,?)").run(NOW, NOW, NOW);
  ins.run(NOW - 3600e3, "shipped", "trk_easypost", "in_transit");
  d.prepare("INSERT INTO tracked_orders(device,brand_id,checkout_id,tracker_id,created) VALUES('d','b','c3','trk_order',?)").run(NOW);
  assert.deepEqual(openNumbers(d, NOW).sort(), ["1ZOPEN", "9400OPEN"], "EasyPost's trk_ trackers come by its webhook, not 17TRACK");
});

test("the poller asks 17TRACK in batches of 40 and hands each answer to every handler", async () => {
  const d = db();
  for (let i = 0; i < 45; i++)
    d.prepare("INSERT INTO relay_events(user_id,received,kind,tracker_id,tracking_status) VALUES('u',?,?,?,?)").run(NOW, "shipped", `N${i}`, "in_transit");
  const bodies = [], heard = [];
  const fetcher = async (url, opts) => {
    const asked = JSON.parse(opts.body);
    bodies.push(asked.length);
    assert.equal(opts.headers["17token"], "k");
    return { ok: true, json: async () => ({ data: { accepted: asked.map(({ number }) => ({ number, track_info: { latest_status: { status: "InTransit" } } })) } }) };
  };
  const p = trackingPoller(d, { env: { TRACK17_API_KEY: "k" }, fetcher, now: () => NOW, sleep: async () => {},
    listeners: [async (x) => heard.push(["a", x.data.number]), async (x) => heard.push(["b", x.data.number])], log: () => {} });
  const r = await p.poll();
  assert.deepEqual(bodies, [40, 5]);
  assert.deepEqual([r.asked, r.answered], [45, 45]);
  assert.equal(heard.length, 90, "both handlers hear every number");
  assert.deepEqual(await trackingPoller(d, { env: {}, fetcher }).poll(), { asked: 0, answered: 0 }, "no key, no calls");
});

test("polling the same status again never repeats a notification; a new step notifies once", async () => {
  const d = db();
  const pushes = [];
  const apns = { configured: () => true, send: async (dev, payload) => { pushes.push(payload.aps.alert.body); return { status: 200 }; } };
  d.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  d.prepare("INSERT INTO tracked_orders(device,brand_id,checkout_id,order_gid,state,tracker_id,item_title,created) VALUES('dev','koba','c','gid://shopify/OrderIdentity/1','shipped','1ZKOBA','Le Discovery Set',?)").run(NOW);
  let status = "InTransit";
  const fetcher = async () => ({ ok: true, json: async () => ({ data: { accepted: [{ number: "1ZKOBA", track_info: { latest_status: { status } } }] } }) });
  const lookup = () => ({ id: "koba", name: "KOBA skincare", domain: "kobaskincare.com" });
  const p = trackingPoller(d, { env: { TRACK17_API_KEY: "k" }, fetcher, now: () => NOW, sleep: async () => {}, log: () => {},
    listeners: [(payload) => track17Update(d, payload, { apns, lookup, log: () => {} })] });
  await p.poll(); await p.poll();
  assert.equal(pushes.length, 0, "still in transit: nothing new to say");
  status = "Delivered";
  await p.poll(); await p.poll();
  assert.deepEqual(pushes, ["Your Le Discovery Set from KOBA skincare was delivered."]);
  assert.deepEqual(openNumbers(d, NOW), [], "a delivered order stops being asked about");
});
