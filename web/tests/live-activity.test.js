import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { installTrackingSchema } from "../server/order-tracking.js";
import { installRelaySchema } from "../server/relay.js";
import { apnsSender } from "../server/restock.js";
import {
  liveActivities, liveActivityRoutes, arrivingToday, nextState, liveStatus, startPayload, updatePayload, endPayload,
  urgent, allDelivered, ATTRIBUTES_TYPE, MAX_PER_HOUR, MAX_ORDERS, LAUNCH_GRACE_MS, endOfDayMs,
} from "../server/live-activity.js";

const sha = (v) => createHash("sha256").update(v).digest("hex");
const key = (c) => c.repeat(64);
const brands = { ripl: { id: "ripl", name: "Ripl Efek" }, koba: { id: "koba", name: "KOBA" } };
const lookup = (id) => brands[id];
// 2026-10-13 15:00 UTC = 11 am in New York.
const NOON = Date.parse("2026-10-13T15:00:00Z");
const START_TOKEN = "ab".repeat(80), UPDATE_TOKEN = "cd".repeat(80);

function database() {
  const db = new Database(":memory:");
  db.exec(`CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT);
    CREATE TABLE mobile_sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE mobile_accounts (user_id TEXT PRIMARY KEY, generation TEXT NOT NULL);
    CREATE TABLE restock_devices (hash TEXT PRIMARY KEY, token TEXT, environment TEXT, updated INTEGER NOT NULL, tz TEXT);
    CREATE TABLE restock_links (device TEXT PRIMARY KEY, user_id TEXT NOT NULL, updated INTEGER NOT NULL);`);
  for (const [id, email, token] of [["google:owner", "divinejdavis@gmail.com", key("1")], ["apple:ada", "ada@example.com", key("2")]]) {
    db.prepare("INSERT INTO users VALUES(?,?,?)").run(id, id, email);
    db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(sha(token), id, Date.now() + 60_000);
    db.prepare("INSERT INTO mobile_accounts VALUES(?,?)").run(id, "g");
  }
  installTrackingSchema(db);
  installRelaySchema(db);
  return db;
}

const order = (db, device, fields) => db.prepare(`INSERT INTO tracked_orders(device, brand_id, checkout_id, order_gid, state, carrier, tracking_number, item_title, est_delivery, created, done, updated)
  VALUES(@device, @brand, @checkout, @gid, @state, @carrier, @number, @item, @est, @created, @done, @updated)`).run({
  device, brand: "ripl", checkout: `c${Math.random()}`, gid: "gid://shopify/Order/1417", state: "shipped", carrier: "UPS", number: "1Z1",
  item: "Laundry Detergent", est: null, created: NOON - 86400_000, done: null, updated: NOON - 3600_000, ...fields });

function recorder({ status = 200, reason = "" } = {}) {
  const sent = [];
  return { sent, configured: () => true, send: async (device, payload, options) => { sent.push({ device, payload, options }); return { status, reason, environment: device.environment }; } };
}

test("carrier status maps onto the island's words, and only today's orders count", () => {
  assert.equal(liveStatus("out_for_delivery", null, "2026-10-13"), "out_for_delivery");
  assert.equal(liveStatus("delivered", null, "2026-10-13"), "delivered");
  assert.equal(liveStatus("shipped", "2026-10-13", "2026-10-13"), "arriving");
  assert.equal(liveStatus("shipped", "2026-10-14", "2026-10-13"), null);
  assert.equal(liveStatus("problem", "2026-10-13", "2026-10-13"), "problem");
  assert.equal(liveStatus("problem", null, "2026-10-13"), null);
  assert.equal(liveStatus(null, null, "2026-10-13"), null);
});

test("arrivingToday reads tracked orders and the account's order email, one entry per package, in the phone's time zone", () => {
  const db = database();
  const dev = sha(key("a"));
  db.prepare("INSERT INTO restock_devices VALUES(?,?,?,?,?)").run(dev, "t", "production", 1, "America/Los_Angeles");
  db.prepare("INSERT INTO restock_links VALUES(?,?,?)").run(dev, "apple:ada", 1);
  order(db, dev, { state: "out_for_delivery", number: "1Z1" });
  order(db, dev, { brand: "koba", state: "shipped", est: "2026-10-13", number: "9400", item: "Headband", gid: "gid://shopify/Order/11906" });
  order(db, dev, { state: "shipped", est: "2026-10-15", number: "LATER" });
  order(db, dev, { state: "delivered", number: "OLD", done: NOON - 3 * 86400_000 });
  // The same UPS package also reached the order email: not twice.
  db.prepare(`INSERT INTO relay_events(user_id, received, kind, brand_name, brand_domain, order_name, tracking_number, tracking_status)
    VALUES('apple:ada', ?, 'shipped', 'Ripl Efek', 'riplefek.com', '#1417', '1Z1', 'out_for_delivery')`).run(NOON - 3600_000);
  db.prepare(`INSERT INTO relay_events(user_id, received, kind, brand_name, brand_domain, order_name, tracking_number, tracking_status, est_delivery)
    VALUES('apple:ada', ?, 'shipped', 'Telfar', 'telfar.net', '#88', 'FX1', 'in_transit', '2026-10-13')`).run(NOON - 3600_000);
  const { today, orders } = arrivingToday(db, dev, { now: NOON, lookup });
  assert.equal(today, "2026-10-13");
  assert.deepEqual(orders.map((o) => [o.brand, o.status]), [["Ripl Efek", "out_for_delivery"], ["KOBA", "arriving"], ["Telfar", "arriving"]]);
  assert.equal(orders[0].item, "Laundry Detergent");
  assert.equal(orders[0].link, "marracat://order?brand=ripl&order=1417");
  assert.equal(orders[2].link, "marracat://order?domain=telfar.net&name=%2388");
  // Another phone sees none of it.
  assert.equal(arrivingToday(db, sha(key("b")), { now: NOON, lookup }).orders.length, 0);
});

test("nextState keeps delivered orders, brings the changed one forward and caps the list", () => {
  const a = { id: "a", brand: "A", status: "out_for_delivery" }, b = { id: "b", brand: "B", status: "arriving" };
  const first = nextState(null, [b, a]);
  assert.deepEqual(first.orders.map((o) => o.id), ["a", "b"]);
  assert.equal(first.index, 0);
  // b goes out for delivery: it is the one shown.
  const second = nextState({ ...first, index: 0 }, [a, { ...b, status: "out_for_delivery" }]);
  assert.equal(second.orders[second.index].id, "b");
  // a delivered drops out of today's query but stays on the card, last.
  const third = nextState(second, [{ ...b, status: "out_for_delivery" }].concat([{ ...a, status: "delivered" }]));
  assert.deepEqual(third.orders.map((o) => [o.id, o.status]), [["b", "out_for_delivery"], ["a", "delivered"]]);
  assert.equal(third.orders[third.index].id, "a");
  const gone = nextState(third, [{ ...b, status: "out_for_delivery" }]);
  assert.deepEqual(gone.orders.map((o) => o.id), ["b", "a"], "a delivered order stays until all are");
  assert.ok(!allDelivered(gone));
  assert.ok(allDelivered(nextState(gone, [{ ...b, status: "delivered" }])));
  const many = Array.from({ length: 9 }, (_, i) => ({ id: `o${i}`, brand: "X", status: "arriving" }));
  assert.equal(nextState(null, many).orders.length, MAX_ORDERS);
  assert.equal(urgent(first, second), true);
  assert.equal(urgent(first, first), false);
});

test("payloads follow Apple's ActivityKit push format", () => {
  const state = { orders: [{ id: "a", brand: "KOBA", item: null, status: "arriving", carrier: null, eta: null, link: null }], index: 0 };
  const start = startPayload(state, NOON, { title: "Arriving today", body: "KOBA" });
  assert.equal(start.aps.event, "start");
  assert.equal(start.aps.timestamp, NOON / 1000);
  assert.equal(start.aps["attributes-type"], ATTRIBUTES_TYPE);
  assert.deepEqual(start.aps.attributes, { kind: "deliveries" });
  assert.ok(start.aps.alert, "a push-to-start needs an alert");
  assert.deepEqual(start.aps["content-state"], state);
  assert.equal(updatePayload(state, NOON).aps.event, "update");
  assert.equal(updatePayload(state, NOON).aps.alert, undefined);
  const end = endPayload(state, NOON, NOON / 1000 + 900);
  assert.equal(end.aps.event, "end");
  assert.equal(end.aps["dismissal-date"], NOON / 1000 + 900);
  assert.ok(JSON.stringify(start).length < 4096, "under APNs' 4 KB");
});

test("the APNs sender sends Live Activity pushes on the liveactivity topic and push type", async () => {
  const requests = [];
  const connectTo = () => {
    const session = new EventEmitter();
    session.close = () => {};
    session.request = (headers) => {
      const req = new EventEmitter();
      req.setTimeout = () => {};
      req.end = () => { requests.push(headers); queueMicrotask(() => { req.emit("response", { ":status": 200 }); req.emit("close"); }); };
      return req;
    };
    return session;
  };
  const { generateKeyPairSync } = await import("node:crypto");
  const { writeFileSync, mkdtempSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const dir = mkdtempSync((await import("node:path")).join(tmpdir(), "apns-"));
  const pem = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ type: "pkcs8", format: "pem" });
  writeFileSync(`${dir}/k.p8`, pem);
  const apns = apnsSender({ APNS_KEY_PATH: `${dir}/k.p8`, APNS_KEY_ID: "K", APNS_TEAM_ID: "T" }, { connectTo });
  await apns.send({ token: START_TOKEN, environment: "production" }, {}, { pushType: "liveactivity", priority: 5 });
  await apns.send({ token: START_TOKEN, environment: "production" }, {});
  assert.equal(requests[0]["apns-topic"], "com.divinedavis.marracat.push-type.liveactivity");
  assert.equal(requests[0]["apns-push-type"], "liveactivity");
  assert.equal(requests[0]["apns-priority"], "5");
  assert.equal(requests[1]["apns-topic"], "com.divinedavis.marracat");
  assert.equal(requests[1]["apns-push-type"], "alert");
  assert.equal(requests[1]["apns-priority"], "10");
});

test("sync starts, updates and ends one activity per phone, paced and never logging a token", async () => {
  const db = database();
  const apns = recorder();
  let clock = NOON;
  const logs = [];
  const live = liveActivities(db, { apns, lookup, now: () => clock, log: (l) => logs.push(l) });
  const dev = sha(key("a"));
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production" });
  assert.equal(await live.sync(dev), "idle", "nothing arriving");
  const ripl = order(db, dev, { state: "out_for_delivery" }).lastInsertRowid;
  const koba = order(db, dev, { brand: "koba", state: "shipped", est: "2026-10-13", number: "9400", gid: "gid://shopify/Order/2" }).lastInsertRowid;
  assert.equal(await live.sync(dev), "started");
  assert.equal(apns.sent[0].device.token, START_TOKEN);
  assert.deepEqual(apns.sent[0].options, { pushType: "liveactivity", priority: 10 });
  assert.equal(apns.sent[0].payload.aps["content-state"].orders.length, 2);
  assert.equal(apns.sent[0].payload.aps.alert.title, "Arriving today");
  assert.equal(await live.sync(dev), "same");
  // KOBA goes out for delivery before the phone has sent its update token.
  db.prepare("UPDATE tracked_orders SET state='out_for_delivery' WHERE id=?").run(koba);
  clock += 120_000;
  assert.equal(await live.sync(dev), "waiting");
  live.save(dev, { update_token: UPDATE_TOKEN, update_env: "production", activity_id: "ACT-12345678" });
  assert.equal(await live.sync(dev), "updated");
  const update = apns.sent.at(-1);
  assert.equal(update.device.token, UPDATE_TOKEN);
  assert.equal(update.payload.aps.event, "update");
  assert.equal(update.options.priority, 10, "a real step change");
  const shown = update.payload.aps["content-state"];
  assert.equal(shown.orders[shown.index].brand, "KOBA");
  // Ripl delivered: within a minute it waits (pacing), then goes.
  db.prepare("UPDATE tracked_orders SET state='delivered', done=? WHERE id=?").run(clock, ripl);
  clock += 10_000;
  assert.equal(await live.sync(dev), "paced");
  clock += 60_000;
  assert.equal(await live.sync(dev), "updated");
  // KOBA delivered: said with an alert, and the card stays for the day
  // (owner, 2026-10-17: until 11:59 pm, or Dismiss).
  db.prepare("UPDATE tracked_orders SET state='delivered', done=? WHERE id=?").run(clock, koba);
  clock += 60_000;
  assert.equal(await live.sync(dev), "updated");
  assert.equal(apns.sent.at(-1).payload.aps.alert.title, "Delivered");
  assert.equal(await live.sync(dev), "same", "everything delivered: it stays");
  // Near Apple's 8 hours (7:00 pm here): we end it, on the Lock Screen up to 4 more hours.
  clock = live.row(dev).started + 8 * 3600_000 - 5 * 60_000;
  assert.equal(await live.sync(dev), "ended");
  const end = apns.sent.at(-1).payload.aps;
  assert.equal(end.event, "end");
  assert.ok(end["content-state"].orders.every((o) => o.status === "delivered"));
  assert.equal(end["dismissal-date"], Math.floor(clock / 1000) + 4 * 3600, "Apple's 4-hour cap comes before 11:59 pm");
  assert.equal(live.row(dev).state, null);
  assert.equal(await live.sync(dev), "idle", "delivered orders never start a new one");
  assert.ok(!logs.some((l) => l.includes(START_TOKEN) || l.includes(UPDATE_TOKEN)));
});

test("at Apple's 8 hours a card with an order still coming leaves at once for its replacement", async () => {
  const db = database();
  const apns = recorder();
  let clock = NOON;
  const live = liveActivities(db, { apns, lookup, now: () => clock, log: () => {} });
  const dev = sha(key("a"));
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production", update_token: UPDATE_TOKEN, update_env: "production",
    activity_id: "ACT-12345678", started: clock - 8 * 3600_000 + 5 * 60_000,
    state: JSON.stringify({ orders: [{ id: "t1", brand: "Bask & Lather Co.", status: "failed" }], index: 0 }) });
  assert.equal(await live.sync(dev), "ended");
  assert.equal(apns.sent.at(-1).payload.aps["dismissal-date"], Math.floor(clock / 1000), "gone now, not beside the new one");
});

test("no more than MAX_PER_HOUR pushes an hour per phone", async () => {
  const db = database();
  const apns = recorder();
  let clock = NOON;
  const live = liveActivities(db, { apns, lookup, now: () => clock, log: () => {} });
  const dev = sha(key("a"));
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production", update_token: UPDATE_TOKEN, update_env: "production",
    state: JSON.stringify({ orders: [{ id: "x", brand: "X", status: "arriving" }], index: 0 }), started: clock });
  const id = order(db, dev, { state: "shipped", est: "2026-10-13" }).lastInsertRowid;
  let sent = 0;
  for (let i = 0; i < 30; i++) {
    db.prepare("UPDATE tracked_orders SET carrier=? WHERE id=?").run(`C${i}`, id);
    clock += 61_000;
    if (await live.sync(dev) === "updated") sent++;
  }
  assert.equal(sent, MAX_PER_HOUR);
});

test("a dead update token clears the activity; a dead start token is dropped", async () => {
  const db = database();
  const apns = recorder({ status: 410, reason: "Unregistered" });
  const live = liveActivities(db, { apns, lookup, now: () => NOON, log: () => {} });
  const dev = sha(key("a"));
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production" });
  order(db, dev, { state: "out_for_delivery" });
  assert.equal(await live.sync(dev), "failed");
  assert.equal(live.row(dev).start_token, null);
  assert.equal(live.row(dev).state, null);
});

test("an order merely due today waits for the morning; out for delivery doesn't", async () => {
  const db = database();
  const night = Date.parse("2026-10-13T08:00:00Z"); // 4 am in New York
  const live = liveActivities(db, { apns: recorder(), lookup, now: () => night, log: () => {} });
  const dev = sha(key("a"));
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production" });
  const id = order(db, dev, { state: "shipped", est: "2026-10-13" }).lastInsertRowid;
  assert.equal(await live.sync(dev), "idle");
  db.prepare("UPDATE tracked_orders SET state='out_for_delivery' WHERE id=?").run(id);
  assert.equal(await live.sync(dev), "started");
});

async function server(t, { apns = recorder(), sleep = async () => {} } = {}) {
  const db = database();
  const app = express();
  const live = liveActivities(db, { apns, lookup, sleep, log: () => {} });
  liveActivityRoutes(app, db, { env: { OWNER_EMAILS: "divinejdavis@gmail.com" }, live, schedule: false });
  const srv = app.listen(0, "127.0.0.1");
  await new Promise((r) => srv.once("listening", r));
  t.after(() => { srv.close(); db.close(); });
  const base = `http://127.0.0.1:${srv.address().port}/api/live-activity/`;
  const call = async (p, device, body, method = body ? "PUT" : "GET", session) => {
    const headers = { "Content-Type": "application/json", ...(device ? { "X-Marracat-Device": device } : {}) };
    if (session) headers.Authorization = "Bearer " + session;
    const r = await fetch(base + p, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await r.text();
    return { status: r.status, data: text ? JSON.parse(text) : null };
  };
  return { db, live, apns, call };
}

test("routes need a device key and validate tokens; status says owner only for the owner's account", async (t) => {
  const { call, live } = await server(t);
  const a = key("a");
  assert.equal((await call("status")).status, 401);
  assert.equal((await call("status", "short")).status, 401);
  assert.deepEqual((await call("status", a)).data, { enabled: true, owner: false });
  assert.deepEqual((await call("status", a, undefined, "GET", key("2"))).data, { enabled: true, owner: false }, "a signed-in shopper is not the owner");
  assert.deepEqual((await call("status", a, undefined, "GET", key("1"))).data, { enabled: true, owner: true });
  assert.equal((await call("start-token", a, { token: "zz", environment: "production" })).status, 400);
  assert.equal((await call("start-token", a, { token: START_TOKEN, environment: "staging" })).status, 400);
  assert.equal((await call("start-token", a, { token: START_TOKEN, environment: "production" })).status, 204);
  assert.equal(live.row(sha(a)).start_token, START_TOKEN);
  // The raw device key is never stored.
  assert.equal(live.row(a), undefined);
  assert.equal((await call("activity", a, { activityID: "ACT-12345678", token: UPDATE_TOKEN, environment: "production" })).status, 409, "no activity running");
  assert.equal((await call("settings", a, { enabled: "no" })).status, 400);
  assert.equal((await call("settings", a, { enabled: false })).status, 204);
  assert.equal((await call("status", a)).data.enabled, false);
});

test("turning Live Activities off ends a running one at once", async (t) => {
  const { call, live, apns } = await server(t);
  const a = key("a"), dev = sha(a);
  live.ensure(dev);
  live.save(dev, { state: JSON.stringify({ orders: [{ id: "x", brand: "X", status: "arriving" }], index: 0 }), started: Date.now(),
    update_token: UPDATE_TOKEN, update_env: "production" });
  assert.equal((await call("settings", a, { enabled: false })).status, 204);
  assert.equal(apns.sent.at(-1).payload.aps.event, "end");
  assert.equal(live.row(dev).state, null);
});

test("a dismissed activity isn't restarted the same day", async (t) => {
  const { call, live, db } = await server(t);
  const a = key("a"), dev = sha(a);
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production", state: JSON.stringify({ orders: [{ id: "t1", brand: "X", status: "out_for_delivery" }], index: 0 }), started: Date.now() });
  assert.equal((await call("activity", a, { activityID: "ACT-12345678", token: UPDATE_TOKEN, environment: "production" })).status, 204);
  assert.equal((await call("activity", a, { activityID: "ACT-12345678" }, "DELETE")).status, 204);
  assert.equal(live.row(dev).state, null);
  order(db, dev, { state: "out_for_delivery" });
  assert.equal(await live.sync(dev), "idle");
});

test("an activity the phone no longer has is forgotten at launch, so the next sync starts a new one", async (t) => {
  const { call, live, db } = await server(t);
  const a = key("a"), dev = sha(a);
  live.ensure(dev);
  const running = { state: JSON.stringify({ orders: [{ id: "t1", brand: "X", status: "out_for_delivery" }], index: 0 }),
    start_token: START_TOKEN, start_env: "production", activity_id: "ACT-12345678", update_token: UPDATE_TOKEN, update_env: "production" };
  assert.equal((await call("running", a, { activityIDs: "ACT-12345678" })).status, 400);
  assert.equal((await call("running", a, { activityIDs: ["bad id!"] })).status, 400);
  // Just started: the phone may not have it yet.
  live.save(dev, { ...running, started: Date.now() - 30_000 });
  assert.equal((await call("running", a, { activityIDs: [] })).status, 204);
  assert.ok(live.row(dev).state, "kept inside the launch grace");
  // Still on the phone: kept.
  live.save(dev, { started: Date.now() - LAUNCH_GRACE_MS - 1000 });
  assert.equal((await call("running", a, { activityIDs: ["ACT-12345678"] })).status, 204);
  assert.ok(live.row(dev).state);
  // On screen before its update token reached us: kept, not started twice
  // (owner, 2026-10-25: two cards for one order).
  live.save(dev, { activity_id: null, update_token: null });
  assert.equal((await call("running", a, { activityIDs: ["ACT-87654321"] })).status, 204);
  assert.ok(live.row(dev).state, "a card the server hasn't heard about yet still counts");
  // Gone after an app update: forgotten, not marked dismissed, and restarted.
  assert.equal((await call("running", a, { activityIDs: [] })).status, 204);
  assert.equal(live.row(dev).state, null);
  assert.equal(live.row(dev).dismissed_day, null);
  order(db, dev, { state: "out_for_delivery" });
  assert.equal(await live.sync(dev), "started");
});

test("a card started late lingers until 11:59 pm; the end comes on the day's last sync", async () => {
  const db = database();
  const apns = recorder();
  const evening = Date.parse("2026-10-13T22:00:00Z"); // 6 pm in New York
  let clock = evening;
  const live = liveActivities(db, { apns, lookup, now: () => clock });
  const dev = sha(key("a"));
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production" });
  const id = order(db, dev, { state: "out_for_delivery" }).lastInsertRowid;
  assert.equal(await live.sync(dev), "started");
  live.save(dev, { update_token: UPDATE_TOKEN, update_env: "production", activity_id: "ACT-12345678" });
  db.prepare("UPDATE tracked_orders SET state='delivered', done=? WHERE id=?").run(clock, id);
  clock += 120_000;
  assert.equal(await live.sync(dev), "updated");
  const dayEnd = endOfDayMs(clock, "America/New_York");
  assert.equal(new Date(dayEnd).toISOString(), "2026-10-14T03:59:00.000Z", "11:59 pm in New York");
  clock = dayEnd - 150_000; // 11:56:30
  assert.equal(await live.sync(dev), "same");
  clock = dayEnd - 90_000; // 11:57:30: the last sync before 11:59
  assert.equal(await live.sync(dev), "ended");
  assert.equal(apns.sent.at(-1).payload.aps["dismissal-date"], Math.floor(dayEnd / 1000));
});

test("Dismiss takes one delivered order off today's card; the last one ends it", async (t) => {
  const { call, live, db, apns } = await server(t);
  const a = key("a"), dev = sha(a);
  live.ensure(dev);
  live.save(dev, { start_token: START_TOKEN, start_env: "production" });
  const ripl = order(db, dev, { state: "delivered", done: Date.now() }).lastInsertRowid;
  order(db, dev, { brand: "koba", state: "out_for_delivery", number: "9400", gid: "gid://shopify/Order/2" });
  assert.equal(await live.sync(dev), "started");
  live.save(dev, { update_token: UPDATE_TOKEN, update_env: "production", activity_id: "ACT-12345678", pushes: "[]" });
  assert.equal((await call("hide", a, { orderID: "bad id!" })).status, 400);
  assert.equal((await call("hide", a, { orderID: `t${ripl}` })).status, 204);
  const shown = JSON.parse(live.row(dev).state).orders.map((o) => o.id);
  assert.ok(!shown.includes(`t${ripl}`), "gone from the card");
  assert.equal(shown.length, 1);
  assert.equal(await live.sync(dev), "same", "and it doesn't come back");
  // KOBA delivered, then dismissed too: nothing left, so the card ends.
  db.prepare("UPDATE tracked_orders SET state='delivered', done=? WHERE brand_id='koba'").run(Date.now());
  live.save(dev, { pushes: "[]" });
  await live.sync(dev);
  const koba = JSON.parse(live.row(dev).state).orders[0].id;
  live.save(dev, { pushes: "[]" });
  assert.equal((await call("hide", a, { orderID: koba })).status, 204);
  assert.equal(apns.sent.at(-1).payload.aps.event, "end");
  assert.equal(live.row(dev).state, null);
  assert.equal(await live.sync(dev), "idle");
});

test("the demo is the owner's only, and runs start → updates → end on this phone", async (t) => {
  const apns = recorder();
  let release;
  const gate = new Promise((r) => { release = r; });
  let sleeps = 0;
  const sleep = async () => { if (sleeps++ === 0) await gate; };
  const { call, live } = await server(t, { apns, sleep });
  const a = key("a"), dev = sha(a);
  assert.equal((await call("demo", a, {}, "POST")).status, 401);
  assert.equal((await call("demo", a, {}, "POST", key("2"))).status, 403, "not the owner");
  assert.equal((await call("demo", a, {}, "POST", key("1"))).status, 409, "no push-to-start token yet");
  await call("start-token", a, { token: START_TOKEN, environment: "production" });
  assert.equal((await call("demo", a, {}, "POST", key("1"))).status, 202);
  assert.equal((await call("demo", a, {}, "POST", key("1"))).status, 409, "one at a time");
  const start = apns.sent[0].payload.aps;
  assert.equal(start.event, "start");
  assert.deepEqual(start["content-state"].orders.map((o) => o.brand), ["Ripl Efek", "KOBA", "Telfar"]);
  // The phone reports the activity's token, then the demo moves on.
  assert.equal((await call("activity", a, { activityID: "ACT-12345678", token: UPDATE_TOKEN, environment: "production" })).status, 204);
  release();
  for (let i = 0; i < 50 && live.row(dev).demo; i++) await new Promise((r) => setTimeout(r, 10));
  const events = apns.sent.map((s) => s.payload.aps.event);
  assert.deepEqual(events, ["start", "update", "update", "update", "end"]);
  const statuses = apns.sent.map((s) => s.payload.aps["content-state"].orders.map((o) => o.status).join(","));
  assert.ok(statuses[1].includes("nearby"));
  assert.ok(statuses[4].split(",").every((s) => s === "delivered"));
  assert.ok(apns.sent.slice(1).every((s) => s.device.token === UPDATE_TOKEN));
  assert.equal(live.row(dev).demo, null, "the demo cleans up after itself");
});
