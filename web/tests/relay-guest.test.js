import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync } from "node:crypto";
import express from "express";
import { getDomain } from "tldts";
import Database from "better-sqlite3";
import nodemailer from "nodemailer";
import { createRelay, relayRoutes, verifiedSender, guestOwner, newLocal, relayGuestsEnabled } from "../server/relay.js";
import { installRestockSchema } from "../server/restock.js";
import { installTrackingSchema, track17Update, deleteTrackedOrders } from "../server/order-tracking.js";
import { syncRelayOrders, relayProgress, devicesFor } from "../server/relay-sync.js";

// Guest order email + order-email -> tracked-order sync (owner, 2026-10-13).

const dkimKey = generateKeyPairSync("rsa", { modulusLength: 2048 });
const dkimPrivate = dkimKey.privateKey.export({ type: "pkcs8", format: "pem" });
const dkimPublic = dkimKey.publicKey.export({ type: "spki", format: "der" }).toString("base64");
const resolver = async (name, type) => {
  if (type === "TXT" && /^s1\._domainkey\./.test(name)) return [[`v=DKIM1; k=rsa; p=${dkimPublic}`]];
  throw Object.assign(new Error("not found"), { code: "ENOTFOUND" });
};
const BRANDS = { "kobaskincare.com": { id: "koba-skincare", name: "KOBA skincare" } };
const brandFor = (d) => { const r = getDomain(String(d || "")); return BRANDS[r] ? { ...BRANDS[r], domain: r } : null; };
const rawMail = ({ subject, text, from = "orders@kobaskincare.com" }, to) =>
  new Promise((resolve, reject) => nodemailer.createTransport({ streamTransport: true, buffer: true })
    .sendMail({ from: { name: "KOBA skincare", address: from }, to, subject, text,
      dkim: { domainName: from.split("@")[1], keySelector: "s1", privateKey: dkimPrivate } },
      (e, info) => (e ? reject(e) : resolve(info.message))));
const confirmed = (n) => ({ subject: `Order #${n} confirmed`, text: `Thank you for your purchase! Order #${n}` });
const deliveredMail = (n) => ({ subject: `A shipment from order #${n} has been delivered`, text: "Your package was delivered." });
const shippedMail = (n) => ({ subject: `A shipment from order #KOBA-${n} is on the way`,
  text: "Your order is on the way. UPS tracking number: 1Z999AA10123456784" });

const KEY_A = "a".repeat(64), KEY_B = "b".repeat(64);
const H = (k) => createHash("sha256").update(k).digest("hex");

function setup(overrides = {}) {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT)");
  db.prepare("INSERT INTO users(id,email) VALUES('google:1','me@example.com'),('google:2','two@example.com')").run();
  db.exec("CREATE TABLE mobile_sessions (hash TEXT, user_id TEXT, expires INTEGER); CREATE TABLE mobile_accounts (user_id TEXT)");
  installRestockSchema(db);
  installTrackingSchema(db);
  const sent = [], pushes = [], logs = [];
  let clock = Date.parse("2026-10-08T03:00:00Z");
  const now = () => clock;
  const sync = () => syncRelayOrders(db, { brandFor, now });
  const relay = createRelay(db, {
    env: { RELAY_SMTP_USER: "hello@marracat.com" },
    forward: async (m) => { sent.push(m); },
    tracker: async (t) => ({ id: t.trackingNumber, status: "in_transit" }),
    apns: { configured: () => true, send: async (d, p) => { pushes.push({ d, p }); return { status: 200 }; } },
    now, log: (m) => logs.push(m), brandFor, verify: (raw) => verifiedSender(raw, { brandFor, resolver }),
    onChange: sync, ...overrides,
  });
  const phone = (hash, token = "tok-" + hash.slice(0, 4)) => db.prepare("INSERT OR REPLACE INTO restock_devices(hash,token,environment,updated) VALUES(?,?,'production',0)").run(hash, token);
  const order = (device, created, number) => db.prepare(`INSERT INTO tracked_orders(device,brand_id,checkout_id,order_gid,created,state,resolved,diagnosis)
    VALUES(?,?,?,?,?,'confirmed',?,'no UCP checkout, order id only')`).run(device, "koba-skincare", `gid://shopify/OrderIdentity/${number}`,
    `gid://shopify/OrderIdentity/${number}`, created, created).lastInsertRowid;
  const session = (user) => {
    const token = createHash("sha256").update(user).digest("hex");
    db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(H(token), user, Date.now() + 1e7);
    db.prepare("INSERT INTO mobile_accounts VALUES(?)").run(user);
    return token;
  };
  return { db, relay, sent, pushes, logs, sync, phone, order, session, tick: (ms) => (clock += ms), now };
}

async function serve(t, db, relay, env = { RELAY_USERS: "*" }) {
  const app = express();
  app.set("trust proxy", "loopback");
  relayRoutes(app, db, relay, { env });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  return async (path, { method = "GET", device, token, body } = {}) => {
    const r = await fetch(base + path, { method, body: body ? JSON.stringify(body) : undefined, headers: {
      "Content-Type": "application/json", ...(device ? { "X-Marracat-Device": device } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) } });
    return { status: r.status, data: await r.json().catch(() => null) };
  };
}

test("addresses are 10 CSPRNG base32 characters", () => {
  const seen = new Set();
  for (let i = 0; i < 2000; i++) {
    const l = newLocal();
    assert.match(l, /^u-[abcdefghijkmnpqrstuvwxyz23456789]{10}$/);
    seen.add(l);
  }
  assert.equal(seen.size, 2000);
  assert.equal(relayGuestsEnabled({ RELAY_USERS: "*" }), true);
  assert.equal(relayGuestsEnabled({ RELAY_USERS: "a@b.co" }), false);
});

test("a guest gets one stable address keyed to the install's hashed device key; no key, no address", async (t) => {
  const { db, relay } = setup();
  const call = await serve(t, db, relay);
  assert.equal((await call("/api/relay/guest")).status, 401);
  assert.equal((await call("/api/relay/guest", { device: "not-a-key" })).status, 401);
  assert.deepEqual((await call("/api/relay/guest", { device: KEY_A })).data, { enabled: true });
  const made = await call("/api/relay/guest", { method: "PUT", device: KEY_A });
  assert.equal(made.status, 200);
  assert.match(made.data.address, /^u-[a-z0-9]{10}@orders\.marracat\.com$/);
  assert.equal(made.data.forwardTo, undefined, "a guest has no inbox to show");
  assert.equal((await call("/api/relay/guest", { method: "PUT", device: KEY_A })).data.address, made.data.address, "stable");
  assert.equal((await call("/api/relay/guest", { device: KEY_A })).data.address, made.data.address);
  assert.notEqual((await call("/api/relay/guest", { method: "PUT", device: KEY_B })).data.address, made.data.address);
  const row = db.prepare("SELECT user_id, device FROM relay_addresses WHERE local=?").get(made.data.address.split("@")[0]);
  assert.deepEqual(row, { user_id: guestOwner(H(KEY_A)), device: H(KEY_A) }, "only the hash is stored");
  assert.equal(JSON.stringify(db.prepare("SELECT * FROM relay_addresses").all()).includes(KEY_A), false);
});

test("guest addresses are off unless the order email is on for everyone", async (t) => {
  const { db, relay } = setup();
  const call = await serve(t, db, relay, { RELAY_USERS: "divinejdavis@gmail.com" });
  assert.equal((await call("/api/relay/guest", { device: KEY_A })).data.enabled, false);
  assert.equal((await call("/api/relay/guest", { method: "PUT", device: KEY_A })).status, 403);
});

test("new guest addresses are capped per install, per day and per IP", async (t) => {
  const { db, relay, tick } = setup();
  // Per install: 3 in 30 days (forgetting and re-making counts).
  for (let i = 0; i < 3; i++) { relay.registerGuest(H(KEY_A)); deleteTrackedOrders(db, H(KEY_A)); }
  assert.throws(() => relay.registerGuest(H(KEY_A)), (e) => e.status === 429);
  tick(31 * 86400_000);
  assert.ok(relay.registerGuest(H(KEY_A)).address);
  // All installs: the daily cap.
  const capped = setup({ env: { RELAY_GUEST_DAILY_MAX: "2" } });
  capped.relay.registerGuest(H("1".repeat(64)));
  capped.relay.registerGuest(H("2".repeat(64)));
  assert.throws(() => capped.relay.registerGuest(H("3".repeat(64))), (e) => e.status === 429);
  assert.ok(capped.logs.some((l) => /cap reached/.test(l)));
  // One IP minting device keys: 10 an hour; an install's existing address is
  // still answered.
  const call = await serve(t, db, relay);
  const statuses = [];
  for (let i = 0; i < 11; i++) statuses.push((await call("/api/relay/guest", { method: "PUT", device: (i + 10).toString(16).padStart(64, "c") })).status);
  assert.deepEqual(statuses.slice(0, 10), Array(10).fill(200));
  assert.equal(statuses[10], 429);
  assert.equal((await call("/api/relay/guest", { method: "PUT", device: "a".padStart(64, "c") })).status, 200);
});

test("a guest's order emails are read, tracked and pushed to its phone, kept unforwarded, and move its tracked order", async () => {
  const t = setup();
  const dev = H(KEY_A);
  t.phone(dev);
  const id = t.order(dev, t.now(), "17374755848579");
  const { address } = t.relay.registerGuest(dev);
  const local = address.split("@")[0];
  t.tick(60_000);
  await t.relay.receive(await rawMail(confirmed("11906"), address), local);
  t.tick(86400_000);
  await t.relay.receive(await rawMail(shippedMail("11906"), address), local);
  assert.equal(t.sent.length, 0, "no inbox to forward to");
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 2, "kept for a sign-in, up to 3 days");
  assert.equal(t.pushes.length, 1);
  assert.equal(t.pushes[0].d.token, "tok-" + dev.slice(0, 4), "the guest's own phone");
  assert.match(t.pushes[0].p.aps.alert.body, /KOBA skincare shipped/);
  const row = t.db.prepare("SELECT * FROM tracked_orders WHERE id=?").get(id);
  assert.deepEqual([row.state, row.carrier, row.tracking_number, row.relay_owner, row.relay_order],
    ["shipped", "UPS", "1Z999AA10123456784", guestOwner(dev), "kobaskincare.com|11906"]);
  assert.equal(row.tracking_url, "https://www.ups.com/track?tracknum=1Z999AA10123456784");
  assert.equal(t.relay.events(guestOwner(dev)).length, 2);
  // Nothing personal in the log: no address, device hash or key.
  for (const l of t.logs) for (const secret of [local, dev, KEY_A]) assert.equal(l.includes(secret), false, l);
  // Unforwarded mail expires with the outbox.
  t.tick(4 * 86400_000);
  await t.relay.retryOutbox();
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 0);
});

test("signing in merges the phone's guest address and events into an account without one", async (tt) => {
  const t = setup();
  const dev = H(KEY_A);
  t.phone(dev);
  t.order(dev, t.now(), "17374755848579");
  const { address } = t.relay.registerGuest(dev);
  await t.relay.receive(await rawMail(confirmed("11906"), address), address.split("@")[0]);
  await t.relay.receive(await rawMail(shippedMail("11906"), address), address.split("@")[0]);
  assert.equal(t.pushes.length, 1);
  const call = await serve(tt, t.db, t.relay);
  const token = t.session("google:1");
  const merged = await call("/api/mobile/relay", { method: "PUT", token, device: KEY_A, body: {} });
  assert.equal(merged.status, 200);
  assert.equal(merged.data.address, address, "the address brands already have is kept");
  assert.equal(merged.data.forwardTo, "me@example.com");
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_addresses").get().n, 1, "one address");
  assert.equal(t.relay.events("google:1").length, 2);
  assert.equal(t.relay.events(guestOwner(dev)).length, 0);
  assert.equal(t.db.prepare("SELECT relay_owner FROM tracked_orders").get().relay_owner, "google:1");
  // The waiting mail now goes to the account's own inbox.
  await t.relay.retryOutbox();
  assert.equal(t.sent.length, 2);
  assert.ok(t.sent.every((m) => m.to === "me@example.com"));
  // Steps already pushed aren't pushed again under the account.
  await t.relay.track17Update({ event: "TRACKING_UPDATED", data: { number: "1Z999AA10123456784", track_info: { latest_status: { status: "InTransit" } } } });
  assert.equal(t.pushes.length, 1);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM push_log WHERE who LIKE 'device:%'").get().n, 0);
});

test("an account that has an address keeps it; the guest one becomes a receiving alias", async (tt) => {
  const t = setup();
  const dev = H(KEY_A);
  const mine = t.relay.register("google:1", null).address;
  const guest = t.relay.registerGuest(dev).address;
  const call = await serve(tt, t.db, t.relay);
  const token = t.session("google:1");
  assert.equal((await call("/api/mobile/relay", { method: "PUT", token, device: KEY_A, body: {} })).data.address, mine);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_addresses").get().n, 1);
  assert.equal(t.relay.ownerOf(guest.split("@")[0]), "google:1");
  await t.relay.receive(await rawMail(confirmed("2000"), guest), guest.split("@")[0]);
  assert.equal(t.relay.events("google:1").length, 1, "an order placed as a guest still reaches the account");
  assert.equal(t.sent[0].to, "me@example.com");
  // Account deletion takes the alias too.
  const { deleteRelayData } = await import("../server/relay.js");
  deleteRelayData(t.db, "google:1");
  assert.equal(t.relay.ownerOf(guest.split("@")[0]), null);
});

test("merging needs the account's session and the phone's own device key", async (tt) => {
  const t = setup();
  const devA = H(KEY_A);
  t.relay.registerGuest(devA);
  const call = await serve(tt, t.db, t.relay);
  assert.equal((await call("/api/mobile/relay", { method: "PUT", device: KEY_A, body: {} })).status, 401, "no session, no merge");
  assert.ok(t.relay.addressFor(guestOwner(devA)), "still the guest's");
  // Signed in on another phone (key B): A's guest data stays A's.
  const token = t.session("google:2");
  await call("/api/mobile/relay", { method: "PUT", token, device: KEY_B, body: {} });
  assert.ok(t.relay.addressFor(guestOwner(devA)));
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_addresses WHERE user_id='google:2'").get().n, 1);
  // A guest key alone can't read anyone's events but its own.
  assert.deepEqual((await call("/api/relay/guest/events", { device: KEY_B })).data.events, []);
});

test("an order email moves the order it belongs to: KOBA #3 stayed confirmed while its email said delivered (2026-10-08)", async () => {
  const t = setup();
  const dev = "f".repeat(64);
  t.phone(dev);
  const { address } = t.relay.register("google:1", dev);
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES(?,?,0)").run(dev, "google:1");
  // Two KOBA orders under a minute apart, as live: #11906's confirmation
  // came 5 s after the first; the second's never named a number.
  const first = t.order(dev, t.now(), "17374755848579");
  t.tick(5_000);
  await t.relay.receive(await rawMail(confirmed("11906"), address), address.split("@")[0]);
  t.tick(43_000);
  const second = t.order(dev, t.now(), "17374756274563");
  t.tick(40_000);
  await t.relay.receive(await rawMail({ subject: "Order confirmed", text: "Thanks for your order" }, address), address.split("@")[0]);
  t.tick(86400_000);
  await t.relay.receive(await rawMail(deliveredMail("11906"), address), address.split("@")[0]);
  const a = t.db.prepare("SELECT * FROM tracked_orders WHERE id=?").get(first);
  const b = t.db.prepare("SELECT * FROM tracked_orders WHERE id=?").get(second);
  assert.equal(a.state, "delivered");
  assert.ok(a.done, "a delivered order closes");
  assert.equal(a.relay_order, "kobaskincare.com|11906");
  assert.equal(b.state, "confirmed", "the other KOBA order isn't this one");
  assert.equal(b.relay_order, null);
  // Idempotent: nothing left to change.
  assert.equal(t.sync(), 0);
});

test("a linked order and its email announce each step once between them", async () => {
  const t = setup();
  const dev = H(KEY_A);
  t.phone(dev);
  const id = t.order(dev, t.now(), "1");
  const { address } = t.relay.registerGuest(dev);
  await t.relay.receive(await rawMail(confirmed("11906"), address), address.split("@")[0]);
  await t.relay.receive(await rawMail(shippedMail("11906"), address), address.split("@")[0]);
  assert.equal(t.pushes.length, 1, "Shipped, from the email");
  assert.equal(t.db.prepare("SELECT tracker_id FROM tracked_orders WHERE id=?").get(id).tracker_id, "1Z999AA10123456784");
  // The carrier says delivered: both the relay and the order-page listener hear it.
  const payload = { event: "TRACKING_UPDATED", data: { number: "1Z999AA10123456784", track_info: { latest_status: { status: "Delivered" } } } };
  const apns = { configured: () => true, send: async (d, p) => { t.pushes.push({ d, p }); return { status: 200 }; } };
  await track17Update(t.db, payload, { apns, lookup: () => ({ id: "koba-skincare", name: "KOBA skincare", domain: "kobaskincare.com" }) });
  await t.relay.track17Update(payload);
  const delivered = t.pushes.filter((p) => p.p.aps.alert.title === "Delivered");
  assert.equal(delivered.length, 1, "one Delivered, whichever side heard it first");
  assert.equal(t.db.prepare("SELECT state FROM tracked_orders WHERE id=?").get(id).state, "delivered");
});

test("progress takes the furthest step from email kinds and carrier status; the owner's phones are found", () => {
  assert.deepEqual(relayProgress([{ kind: "confirmation" }, { kind: "other", tracking_status: "out_for_delivery" }]).step, "out_for_delivery");
  assert.equal(relayProgress([{ kind: "shipped", tracking_status: "failure" }]).step, "shipped", "a problem isn't a step");
  assert.equal(relayProgress([]).step, null);
  const t = setup();
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES('d1','google:1',0)").run();
  t.relay.register("google:1", "d2");
  assert.deepEqual(devicesFor(t.db, "google:1").sort(), ["d1", "d2"]);
  assert.deepEqual(devicesFor(t.db, guestOwner("d9")), ["d9"]);
});

test("forgetting an install's orders deletes its guest address and what it received; idle guests expire", async () => {
  const t = setup();
  const dev = H(KEY_A);
  const { address } = t.relay.registerGuest(dev);
  await t.relay.receive(await rawMail(confirmed("1"), address), address.split("@")[0]);
  deleteTrackedOrders(t.db, dev);
  assert.equal(t.relay.addressFor(guestOwner(dev)), null);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_events").get().n, 0);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 0);
  const idle = H(KEY_B);
  t.relay.registerGuest(idle);
  t.tick(181 * 86400_000);
  t.relay.expireGuests();
  assert.equal(t.relay.addressFor(guestOwner(idle)), null);
});

test("a matching tracking number or item links an order even when the emails came later", () => {
  const t = setup();
  const dev = "e".repeat(64);
  t.relay.register("google:1", dev);
  const base = t.now();
  const a = t.order(dev, base, "1");
  const b = t.order(dev, base + 1000, "2");
  t.db.prepare("UPDATE tracked_orders SET tracking_number='1ZB' WHERE id=?").run(a);
  t.db.prepare("UPDATE tracked_orders SET item_title='Headband' WHERE id=?").run(b);
  const ins = t.db.prepare(`INSERT INTO relay_events(user_id,received,kind,brand_domain,order_name,tracking_number,item_title) VALUES('google:1',?,?,'kobaskincare.com',?,?,?)`);
  ins.run(base + 5000, "shipped", "#KOBA-7", "1ZB", null);
  ins.run(base + 6000, "delivered", "#8", null, "Headband");
  t.sync();
  const row = (id) => t.db.prepare("SELECT relay_order, state FROM tracked_orders WHERE id=?").get(id);
  assert.deepEqual(row(a), { relay_order: "kobaskincare.com|7", state: "shipped" }, "by tracking number");
  assert.deepEqual(row(b), { relay_order: "kobaskincare.com|8", state: "delivered" }, "by the item");
});
