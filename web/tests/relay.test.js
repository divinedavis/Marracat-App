import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, createHmac, generateKeyPairSync } from "node:crypto";
import { getDomain } from "tldts";
import Database from "better-sqlite3";
import nodemailer from "nodemailer";
import { parseOrderEmail, eventKind, findTracking, findItems, carrierFor } from "../server/relay-parse.js";
import { TRACK17_CARRIERS, orderKey, createRelay, relayEnabledFor, validEasyPostSignature, valid17TrackSignature, statusFrom17Track, seventeenTrack, trackerFor, stepForTrackerStatus, startRelaySMTP, deleteRelayData, installRelaySchema, verifiedSender } from "../server/relay.js";
import { installRestockSchema } from "../server/restock.js";
import { installTrackingSchema } from "../server/order-tracking.js";

// Shopify's stock notification templates, trimmed to what the parser reads.
const TOKEN = "a1b2c3d4e5f60718293a4b5c6d7e8f90", KEY = "0f9e8d7c6b5a49382716f5e4d3c2b1a0";
const STATUS = `https://eparaskincare.com/29585506383/orders/${TOKEN}/authenticate?key=${KEY}`;
const confirmation = {
  subject: "Order #1042 confirmed",
  fromName: "Epara Skincare", fromAddress: "hello@eparaskincare.com",
  html: `<table><tr><td><h2>Thank you for your purchase!</h2><p>We're getting your order ready to be shipped.</p>
    <a href="${STATUS.replace(/&/g, "&amp;")}" class="button__text">View your order</a>
    <span>Order #1042</span></td></tr></table>`,
  text: `Thank you for your purchase!\nView your order: ${STATUS}\nOrder #1042`,
};
const shipped = {
  subject: "A shipment from order #1042 is on the way",
  fromName: "Epara Skincare", fromAddress: "hello@eparaskincare.com",
  html: `<p>Your order is on the way. Track your shipment to see the delivery status.</p>
    <a href="https://tools.usps.com/go/TrackConfirmAction?tLabels=9400111899223197428490">Track your shipment</a>
    <p>USPS tracking number: 9400111899223197428490</p><a href="${STATUS}">View your order</a>`,
  text: "",
};
const upsShipped = { subject: "Your order is on the way", fromName: "Scotch Porter", fromAddress: "support@scotchporter.com",
  html: `<a href="https://www.ups.com/track?loc=en_US&amp;tracknum=1Z999AA10123456784&amp;requester=ST/">Track</a>`, text: "" };
const fedexShipped = { subject: "Shipping update for order #SP-2231", fromName: "Brand", fromAddress: "orders@brand.com",
  html: `<a href="https://www.fedex.com/fedextrack/?trknbr=794699999999">Track</a>`, text: "" };
const outForDelivery = { subject: "A shipment from order #1042 is out for delivery", fromName: "Epara Skincare", fromAddress: "hello@eparaskincare.com", html: "", text: "Your order is out for delivery." };
const delivered = { subject: "A shipment from order #1042 has been delivered", fromName: "Epara Skincare", fromAddress: "hello@eparaskincare.com", html: "", text: "Your package was delivered." };
const marketing = { subject: "20% off this weekend only", fromName: "Epara Skincare", fromAddress: "news@eparaskincare.com", html: "<p>New arrivals</p>", text: "" };

test("an order confirmation gives the order number, status page and brand", () => {
  const p = parseOrderEmail(confirmation);
  assert.equal(p.kind, "confirmation");
  assert.equal(p.orderName, "#1042");
  assert.equal(p.statusURL, STATUS);
  assert.equal(p.brandDomain, "eparaskincare.com");
  assert.equal(p.brandName, "Epara Skincare");
  assert.equal(p.trackingNumber, null);
});
test("shipping emails give carrier and tracking number", () => {
  const usps = parseOrderEmail(shipped);
  assert.deepEqual([usps.kind, usps.orderName, usps.carrier, usps.trackingNumber], ["shipped", "#1042", "USPS", "9400111899223197428490"]);
  const ups = parseOrderEmail(upsShipped);
  assert.deepEqual([ups.kind, ups.carrier, ups.trackingNumber, ups.brandDomain], ["shipped", "UPS", "1Z999AA10123456784", "scotchporter.com"]);
  const fedex = parseOrderEmail(fedexShipped);
  assert.deepEqual([fedex.kind, fedex.carrier, fedex.trackingNumber, fedex.orderName], ["shipped", "FedEx", "794699999999", "#SP-2231"]);
});
test("out for delivery, delivered and unrelated mail are told apart", () => {
  assert.equal(parseOrderEmail(outForDelivery).kind, "out_for_delivery");
  assert.equal(parseOrderEmail(delivered).kind, "delivered");
  assert.equal(parseOrderEmail(marketing).kind, "other");
  assert.equal(eventKind("Your order has been cancelled"), "cancelled");
  assert.equal(findTracking("<p>Tracking number: 1Z12345E0205271688</p>", "").trackingNumber, "1Z12345E0205271688");
});

// DKIM: one test key, published for every domain by a fake resolver, so mail
// signed "as" a domain verifies exactly as real DNS would make it.
const dkimKey = generateKeyPairSync("rsa", { modulusLength: 2048 });
const dkimPrivate = dkimKey.privateKey.export({ type: "pkcs8", format: "pem" });
const dkimPublic = dkimKey.publicKey.export({ type: "spki", format: "der" }).toString("base64");
const resolver = async (name, type) => {
  if (type === "TXT" && /^s1\._domainkey\./.test(name)) return [[`v=DKIM1; k=rsa; p=${dkimPublic}`]];
  throw Object.assign(new Error("not found"), { code: "ENOTFOUND" });
};
// The catalog's brands, by domain.
const BRANDS = { "eparaskincare.com": "Epara Skincare", "scotchporter.com": "Scotch Porter", "brand.com": "Brand" };
const brandFor = (d) => { const r = getDomain(String(d || "")); return BRANDS[r] ? { id: r, name: BRANDS[r], domain: r } : null; };

function setup(overrides = {}) {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT)");
  db.prepare("INSERT INTO users(id,email) VALUES('google:1','me@example.com'),('u1','u1@example.com')").run();
  installRestockSchema(db);
  const sent = [], pushes = [], trackers = [], logs = [];
  let clock = Date.parse("2026-10-01T12:00:00Z");
  const relay = createRelay(db, {
    env: { RELAY_SMTP_USER: "hello@marracat.com", EASYPOST_DAILY_MAX: "2" },
    forward: async (m) => { sent.push(m); },
    tracker: async (t) => { trackers.push(t); return { id: `trk_${trackers.length}`, status: "pre_transit" }; },
    apns: { configured: () => true, send: async (d, p) => { pushes.push({ d, p }); return { status: 200 }; } },
    now: () => clock, log: (m) => logs.push(m),
    brandFor, verify: (raw) => verifiedSender(raw, { brandFor, resolver }),
    ...overrides,
  });
  return { db, relay, sent, pushes, trackers, logs, tick: (ms) => (clock += ms) };
}
// A message signed by the From domain (or `signAs`; null = unsigned).
const rawMail = ({ subject, html, text, fromName, fromAddress, attachments }, to, { signAs = fromAddress.split("@")[1] } = {}) =>
  new Promise((resolve, reject) => nodemailer.createTransport({ streamTransport: true, buffer: true })
    .sendMail({ from: { name: fromName, address: fromAddress }, to, subject, html: html || undefined, text: text || undefined, attachments,
      ...(signAs ? { dkim: { domainName: signAs, keySelector: "s1", privateKey: dkimPrivate } } : {}) },
      (e, info) => (e ? reject(e) : resolve(info.message))));

test("only flagged accounts get an address; it's stable and forwards only to the account's own email", () => {
  assert.equal(relayEnabledFor("DivineJDavis@gmail.com", {}), true);
  assert.equal(relayEnabledFor("someone@else.com", {}), false);
  assert.equal(relayEnabledFor("a@b.co", { RELAY_USERS: "a@b.co,c@d.co" }), true);
  const { db, relay } = setup();
  const a = relay.register("google:1", null);
  assert.match(a.address, /^u-[a-z0-9]{10}@orders\.marracat\.com$/);
  assert.equal(a.forwardTo, "me@example.com");
  assert.equal(relay.register("google:1", null).address, a.address);
  // No email on the sign-in (Apple can withhold it): no address.
  db.prepare("INSERT INTO users(id,email) VALUES('apple:2',NULL),('apple:3',?)").run(a.address);
  assert.throws(() => relay.register("apple:2", null), /no email/);
  assert.throws(() => relay.register("apple:3", null), /no email/, "never a relay address itself");
});

test("an address set up to forward elsewhere is moved to the account's email", () => {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT)");
  db.prepare("INSERT INTO users(id,email) VALUES('google:1','me@example.com')").run();
  installRelaySchema(db);
  db.prepare("INSERT INTO relay_addresses(local,user_id,forward_to,created,updated) VALUES('u-abcdefghjk','google:1','victim@elsewhere.com',0,0)").run();
  const relay = createRelay(db, { forward: null, tracker: null, apns: null });
  assert.equal(relay.addressFor("google:1").forwardTo, "me@example.com");
});

test("the PUT route ignores a forwardTo the app sends", async () => {
  const { relayRoutes } = await import("../server/relay.js");
  const express = (await import("express")).default;
  const { db, relay } = setup();
  db.exec("CREATE TABLE mobile_sessions (hash TEXT, user_id TEXT, expires INTEGER); CREATE TABLE mobile_accounts (user_id TEXT)");
  const { createHash } = await import("node:crypto");
  const token = "a".repeat(64);
  db.prepare("INSERT INTO mobile_sessions VALUES(?,?,?)").run(createHash("sha256").update(token).digest("hex"), "google:1", Date.now() + 1e6);
  db.prepare("INSERT INTO mobile_accounts VALUES('google:1')").run();
  const app = express();
  relayRoutes(app, db, relay, { env: { RELAY_USERS: "*" } });
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  const res = await fetch(`http://127.0.0.1:${server.address().port}/api/mobile/relay`, {
    method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ forwardTo: "victim@elsewhere.com" }) });
  server.close();
  const body = await res.json();
  assert.equal(res.status, 200);
  assert.equal(body.forwardTo, "me@example.com");
});

test("a brand's email is stored, forwarded as plain text under the catalog's name, and its raw copy dropped", async () => {
  const { db, relay, sent } = setup();
  const { address } = relay.register("google:1", null);
  const event = await relay.receive(await rawMail({ ...confirmation, fromName: "Chase Fraud Dept",
    attachments: [{ filename: "invoice.html", content: "<form>password</form>" }] }, address), address.split("@")[0]);
  assert.equal(event.order_name, "#1042");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, "me@example.com");
  assert.deepEqual(sent[0].from, { name: "Epara Skincare via Marracat", address: "hello@marracat.com" }, "the catalog's name, not the display name");
  assert.equal(sent[0].replyTo, "hello@eparaskincare.com");
  assert.equal(sent[0].subject, "Order #1042 confirmed");
  assert.equal(sent[0].html, undefined, "plain text only");
  assert.equal(sent[0].attachments, undefined, "no attachments");
  assert.match(sent[0].text, /^Forwarded by Marracat from Epara Skincare \(eparaskincare\.com; sender verified\)/);
  assert.match(sent[0].text, /View your order/);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 0);
  assert.ok(db.prepare("SELECT forwarded FROM relay_events").get().forwarded);
  const [e] = relay.events("google:1");
  assert.deepEqual([e.kind, e.orderName, e.brandDomain, e.step], ["confirmation", "#1042", "eparaskincare.com", "confirmation"]);
  assert.equal(e.statusURL, undefined, "the status link's key stays on the server");
});

test("mail for an unknown address is ignored", async () => {
  const { relay, sent } = setup();
  assert.equal(await relay.receive(await rawMail(confirmation, "u-zzzzzzzzzz@orders.marracat.com"), "u-zzzzzzzzzz"), null);
  assert.equal(sent.length, 0);
});

test("a failed forward is kept and retried, then the raw copy expires", async () => {
  let fail = true;
  const sent = [];
  const t = setup({ forward: async (m) => { if (fail) throw new Error("down"); sent.push(m); } });
  const { address } = t.relay.register("google:1", null);
  await t.relay.receive(await rawMail(confirmation, address), address.split("@")[0]);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 1);
  fail = false; t.tick(11 * 60_000);
  await t.relay.retryOutbox();
  assert.equal(sent.length, 1);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 0);
  fail = true;
  await t.relay.receive(await rawMail(marketing, address), address.split("@")[0]);
  t.tick(4 * 86400_000);
  await t.relay.retryOutbox();
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_outbox").get().n, 0, "raw mail is gone after 3 days");
});

test("a shipping email starts one tracker per number, capped per day, and pushes Shipped", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','a'||hex(randomblob(32)),'production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  const local = address.split("@")[0];
  await t.relay.receive(await rawMail(shipped, address), local);
  await t.relay.receive(await rawMail(shipped, address), local);
  assert.equal(t.trackers.length, 1, "the same tracking number is tracked once");
  assert.deepEqual(t.trackers[0], { trackingNumber: "9400111899223197428490", carrier: "USPS" });
  assert.equal(t.pushes.length, 1, "the same shipping email twice notifies once (owner, 2026-10-09)");
  assert.equal(t.pushes[0].p.aps.alert.title, "Shipped");
  assert.match(t.pushes[0].p.aps.alert.body, /Epara Skincare shipped your order #1042/);
  await t.relay.receive(await rawMail(upsShipped, address), local);
  await t.relay.receive(await rawMail(fedexShipped, address), local);
  assert.equal(t.trackers.length, 2, "the daily cap (2) holds");
  assert.ok(t.logs.some((l) => /daily cap reached/.test(l)));
});

test("EasyPost updates move the tracker and push each new step once", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  await t.relay.receive(await rawMail(shipped, address), address.split("@")[0]);
  const before = t.pushes.length;
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "out_for_delivery" } });
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "out_for_delivery" } });
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "delivered" } });
  assert.deepEqual(t.pushes.slice(before).map((p) => p.p.aps.alert.title), ["Out for delivery", "Delivered"]);
  assert.equal(t.relay.events("google:1")[0].trackingStep, "delivered");
  assert.equal(stepForTrackerStatus("in_transit"), "shipped");
  assert.equal(stepForTrackerStatus("return_to_sender"), "problem");
});

test("the EasyPost webhook signature is checked", () => {
  const body = Buffer.from('{"description":"tracker.updated"}');
  const good = "hmac-sha256-hex=" + createHmac("sha256", "s3cret").update(body).digest("hex");
  assert.equal(validEasyPostSignature(body, good, "s3cret"), true);
  assert.equal(validEasyPostSignature(body, good, "other"), false);
  assert.equal(validEasyPostSignature(body, undefined, "s3cret"), false);
  assert.equal(validEasyPostSignature(body, good, undefined), false);
});

test("17TRACK registers the number with its carrier code and treats 'already registered' as tracked", async () => {
  const calls = [];
  const reply = (data) => ({ ok: true, json: async () => ({ code: 0, data }) });
  let next = reply({ accepted: [{ number: "1Z999AA10123456784", carrier: 100002 }], rejected: [] });
  const track = seventeenTrack({ TRACK17_API_KEY: "k" }, async (url, init) => { calls.push({ url, init }); return next; });
  assert.equal(track.service, "17TRACK");
  assert.deepEqual(await track({ trackingNumber: "1Z999AA10123456784", carrier: "UPS" }), { id: "1Z999AA10123456784", status: null, estDelivery: null });
  assert.equal(calls[0].url, "https://api.17track.net/track/v2.4/register");
  assert.equal(calls[0].init.headers["17token"], "k");
  assert.deepEqual(JSON.parse(calls[0].init.body), [{ number: "1Z999AA10123456784", carrier: 100002 }]);
  // An unknown carrier is left to 17TRACK's auto-detection.
  await track({ trackingNumber: "LX123456789", carrier: null });
  assert.deepEqual(JSON.parse(calls[1].init.body), [{ number: "LX123456789" }]);
  next = reply({ accepted: [], rejected: [{ number: "N1", error: { code: -18019901, message: "already registered" } }] });
  assert.equal((await track({ trackingNumber: "N1" })).id, "N1");
  next = reply({ accepted: [], rejected: [{ number: "N2", error: { code: -18019903, message: "carrier not detected" } }] });
  await assert.rejects(track({ trackingNumber: "N2" }), /-18019903/);
  assert.equal(seventeenTrack({}), null);
});

test("17TRACK pushes move the tracker, push each new step once and carry the expected day", async () => {
  const t = setup({ tracker: Object.assign(async ({ trackingNumber }) => ({ id: trackingNumber, status: null }), { service: "17TRACK" }) });
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('d1','tok1','production',0)").run();
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES('d1','u1',0)").run();
  await t.relay.addTracking("u1", { trackingNumber: "9400111899223197428490", carrier: "USPS", orderName: "#7" });
  const push = (status, sub, to) => t.relay.track17Update({ event: "TRACKING_UPDATED", data: { number: "9400111899223197428490", carrier: 21051,
    track_info: { latest_status: { status, sub_status: sub }, time_metrics: { estimated_delivery_date: { source: "Official", from: null, to } } } } });
  assert.equal(await push("InTransit", "InTransit_Other", "2026-10-03T00:00:00-04:00"), 1);
  assert.equal(t.relay.events("u1")[0].estDelivery, "2026-10-03");
  await push("OutForDelivery", "OutForDelivery_Other", null);
  await push("OutForDelivery", "OutForDelivery_Other", null);
  await push("Delivered", "Delivered_Other", null);
  assert.deepEqual(t.pushes.map((p) => p.p.aps.alert.title), ["Out for delivery", "Delivered"]);
  assert.equal(t.relay.events("u1")[0].trackingStatus, "delivered");
  assert.equal(await t.relay.track17Update({ event: "TRACKING_STOPPED", data: { number: "9400111899223197428490" } }), 0);
  assert.ok(t.logs.some((l) => /^17TRACK tracker 9400111899223197428490 created/.test(l)));
});

test("17TRACK statuses map onto the relay's words", () => {
  assert.equal(statusFrom17Track({ status: "InfoReceived" }), "pre_transit");
  assert.equal(statusFrom17Track({ status: "AvailableForPickup" }), "available_for_pickup");
  assert.equal(statusFrom17Track({ status: "DeliveryFailure" }), "failure");
  assert.equal(statusFrom17Track({ status: "Exception", sub_status: "Exception_Returning" }), "return_to_sender");
  assert.equal(statusFrom17Track({ status: "Exception", sub_status: "Exception_Damage" }), "failure");
  assert.equal(statusFrom17Track({ status: "NotFound" }), "unknown");
  assert.equal(stepForTrackerStatus(statusFrom17Track({ status: "Exception", sub_status: "Exception_Returned" })), "problem");
});

test("the 17TRACK webhook signature is sha256 of body + '/' + key", () => {
  const body = Buffer.from('{"event":"TRACKING_UPDATED"}');
  const good = createHash("sha256").update(body.toString() + "/k3y").digest("hex");
  assert.equal(valid17TrackSignature(body, good, "k3y"), true);
  assert.equal(valid17TrackSignature(body, good.toUpperCase(), "k3y"), true);
  assert.equal(valid17TrackSignature(body, good, "other"), false);
  assert.equal(valid17TrackSignature(body, undefined, "k3y"), false);
  assert.equal(valid17TrackSignature(body, good, undefined), false);
});

test("no tracker service configured: tracking is skipped cleanly", async () => {
  const t = setup({ tracker: null });
  const { address } = t.relay.register("google:1", null);
  const e = await t.relay.receive(await rawMail(shipped, address), address.split("@")[0]);
  assert.equal(e.tracking_number, "9400111899223197428490");
  assert.equal(t.db.prepare("SELECT tracker_id FROM relay_events").get().tracker_id, null);
});

test("deleting the account deletes the address, events and any pending mail", async () => {
  const t = setup({ forward: async () => { throw new Error("down"); } });
  const { address } = t.relay.register("google:1", null);
  await t.relay.receive(await rawMail(confirmation, address), address.split("@")[0]);
  deleteRelayData(t.db, "google:1");
  for (const table of ["relay_addresses", "relay_events", "relay_outbox"])
    assert.equal(t.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n, 0, table);
});

test("the SMTP server takes mail only for real relay addresses and is not an open relay", async () => {
  const t = setup();
  const { address } = t.relay.register("google:1", null);
  const server = startRelaySMTP(t.relay, t.db, { env: { RELAY_SMTP_LISTEN: "25899" }, log: () => {} });
  await new Promise((r) => setTimeout(r, 200));
  const client = nodemailer.createTransport({ host: "127.0.0.1", port: 25899, secure: false, ignoreTLS: true, tls: { rejectUnauthorized: false },
    dkim: { domainName: "eparaskincare.com", keySelector: "s1", privateKey: dkimPrivate } });
  const send = (to) => client.sendMail({ from: "hello@eparaskincare.com", to, subject: confirmation.subject, html: confirmation.html });
  await send(address);
  assert.equal(t.sent.length, 1);
  await assert.rejects(send("u-zzzzzzzzzz@orders.marracat.com"), /550/);
  await assert.rejects(send("someone@gmail.com"), /554/);
  server.close();
});

test("one address forwards at most 60 emails a day; the rest are only read", async () => {
  const t = setup();
  const { address } = t.relay.register("google:1", null);
  const raw = await rawMail(marketing, address);
  for (let i = 0; i < 62; i++) await t.relay.receive(raw, address.split("@")[0]);
  assert.equal(t.sent.length, 60);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_events").get().n, 62);
  assert.ok(t.logs.some((l) => /cap for one address/.test(l)));
});

// Owner, 2026-10-05: notify when it shipped, the morning it's due, if it's
// rescheduled, and when it's delivered.
test("a tracking number added by hand is tracked, and pushes reach every signed-in phone", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated,tz) VALUES('d1','tok1','production',0,'America/Los_Angeles'),('d2','tok2','production',0,NULL)").run();
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES('d1','u1',0),('d2','u1',0)").run();
  const e = await t.relay.addTracking("u1", { trackingNumber: "1Z999AA10123456784", brandName: "The Butter Bar", brandDomain: "thebutterbar.com", orderName: "#79242" });
  assert.equal(e.tracker_id, "trk_1");
  assert.equal(t.trackers[0].trackingNumber, "1Z999AA10123456784");
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "delivered" } });
  assert.deepEqual(t.pushes.map((p) => p.d.token).sort(), ["tok1", "tok2"]);
  assert.equal(t.pushes[0].p.aps.alert.title, "Delivered");
});

test("'Arriving today' goes out at 8 am on the expected day in the phone's time zone, once", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated,tz) VALUES('d1','tok1','production',0,'America/Los_Angeles')").run();
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES('d1','u1',0)").run();
  await t.relay.addTracking("u1", { trackingNumber: "9400111899223197428490", orderName: "#1" });
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "in_transit", est_delivery_date: "2026-10-01T00:00:00Z" } });
  // 12:00 UTC is 5 am in Los Angeles: too early.
  assert.equal(await t.relay.morningNotes(), 0);
  t.tick(3 * 3600_000);   // 8 am Pacific
  assert.equal(await t.relay.morningNotes(), 1);
  assert.equal(t.pushes.at(-1).p.aps.alert.title, "Arriving today");
  t.tick(3600_000);
  assert.equal(await t.relay.morningNotes(), 0, "once a day");
});

test("a later delivery day from the carrier is a 'rescheduled' push naming the new day", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('d1','tok1','production',0)").run();
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES('d1','u1',0)").run();
  await t.relay.addTracking("u1", { trackingNumber: "9400111899223197428490" });
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "in_transit", est_delivery_date: "2026-10-08T00:00:00Z" } });
  assert.equal(t.pushes.length, 0, "the first expected day isn't news");
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "in_transit", est_delivery_date: "2026-10-10T00:00:00Z" } });
  assert.equal(t.pushes.at(-1).p.aps.alert.title, "Delivery rescheduled");
  assert.match(t.pushes.at(-1).p.aps.alert.body, /Saturday, Oct 10/);
  await t.relay.trackerUpdate({ description: "tracker.updated", result: { id: "trk_1", status: "out_for_delivery", est_delivery_date: "2026-10-10T00:00:00Z" } });
  assert.equal(t.pushes.at(-1).p.aps.alert.title, "Out for delivery");
});

test("RELAY_USERS='*' turns the order email on for every account", () => {
  assert.equal(relayEnabledFor("someone@example.com", { RELAY_USERS: "*" }), true);
  assert.equal(relayEnabledFor("someone@example.com", { RELAY_USERS: "divinejdavis@gmail.com" }), false);
});

// Audit 2026-10-07 (M1): only mail DKIM proves came from a catalog brand's
// domain, or from Shopify / Big Cartel, is forwarded, tracked or pushed.
test("unsigned, misaligned or non-brand mail is dropped: no forward, tracker or push", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  const local = address.split("@")[0];
  // Spoofed From with no signature.
  assert.equal(await t.relay.receive(await rawMail(shipped, address, { signAs: null }), local), null);
  // Signed, but by another domain than the From (not aligned).
  assert.equal(await t.relay.receive(await rawMail(shipped, address, { signAs: "attacker.example" }), local), null);
  // Aligned, but the domain is no catalog brand.
  assert.equal(await t.relay.receive(await rawMail({ ...shipped, fromName: "Epara Skincare", fromAddress: "orders@attacker.example" }, address), local), null);
  assert.deepEqual([t.sent.length, t.trackers.length, t.pushes.length], [0, 0, 0]);
  assert.equal(t.db.prepare("SELECT COUNT(*) n FROM relay_events").get().n, 0);
  assert.ok(t.logs.some((l) => /without a brand or platform DKIM/.test(l)));
});

test("Shopify-signed notification mail is accepted and named from the catalog by its store link", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  const viaShopify = { ...shipped, fromName: "Totally Real Bank", fromAddress: "store+123@t.shopifyemail.com" };
  const e = await t.relay.receive(await rawMail(viaShopify, address, { signAs: "shopifyemail.com" }), address.split("@")[0]);
  assert.equal(e.brand_name, "Epara Skincare", "the store link names a catalog brand");
  assert.equal(e.sender_domain, "shopifyemail.com");
  assert.equal(t.sent.length, 1);
  assert.equal(t.sent[0].replyTo, "store+123@t.shopifyemail.com");
  // 2026-11-12: any shop on the platform could have sent it, so the note
  // says what was proved (the platform) and no longer "sender verified".
  assert.match(t.sent[0].text, /^Forwarded by Marracat from Epara Skincare \(sent through shopifyemail\.com; the shop itself isn't verified\)/);
  assert.equal(t.pushes.length, 1);
  assert.match(t.pushes[0].p.aps.alert.body, /^Epara Skincare shipped/);
});

test("a Shopify shipping email's item list names what shipped", () => {
  const html = `<table><tr><td><span class="order-list__item-title">Keep It Together Headband&nbsp;×&nbsp;1</span></td></tr>
    <tr><td><span class="order-list__item-title">Glow Serum × 2</span></td></tr></table>`;
  assert.deepEqual(findItems(html), { title: "Keep It Together Headband", count: 2 });
  assert.equal(findItems("<p>No items here</p>"), null);
  const p = parseOrderEmail({ ...shipped, html: shipped.html + html });
  assert.deepEqual([p.itemTitle, p.itemCount], ["Keep It Together Headband", 2]);
});

test("Shipped from an order email names the item: the email's, else the one order the app placed with that brand", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  const local = address.split("@")[0];
  const item = `<span class="order-list__item-title">Keep It Together Headband × 1</span>`;
  await t.relay.receive(await rawMail({ ...shipped, html: shipped.html + item }, address), local);
  assert.equal(t.pushes.at(-1).p.aps.alert.body, "Epara Skincare shipped your Keep It Together Headband");
  assert.deepEqual(t.pushes.at(-1).p.orderEvent, { brandDomain: "eparaskincare.com", orderName: "#1042" }, "the tap finds the order by these");

  // No item list in the email: the item the app named for this brand's order.
  installTrackingSchema(t.db);
  t.db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES('dev','google:1',0)").run();
  const order = (title) => t.db.prepare(`INSERT INTO tracked_orders(device,brand_id,checkout_id,item_title,item_count,created)
    VALUES('dev','eparaskincare.com',?,?,1,?)`).run(Math.random().toString(36), title, Date.parse("2026-09-30T12:00:00Z"));
  order("Glow Serum");
  await t.relay.receive(await rawMail({ ...shipped, subject: "A shipment from order #1043 is on the way" }, address), local);
  assert.equal(t.pushes.at(-1).p.aps.alert.body, "Epara Skincare shipped your Glow Serum");
  // Two recent orders with different items: can't tell which shipped.
  order("Body Butter");
  await t.relay.receive(await rawMail({ ...shipped, subject: "A shipment from order #1044 is on the way" }, address), local);
  assert.equal(t.pushes.at(-1).p.aps.alert.body, "Epara Skincare shipped your order #1044.");
});

test("the app names an order's items by its number, and every later push says them", async () => {
  assert.equal(orderKey("#KOBA-11906"), "11906");
  assert.equal(orderKey("#11906"), "11906");
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  await t.relay.receive(await rawMail(shipped, address), address.split("@")[0]);
  assert.match(t.pushes.at(-1).p.aps.alert.body, /shipped your order #1042/, "no item known yet");
  assert.equal(t.relay.setItems("google:1", [{ brandDomain: "eparaskincare.com", orderName: "1042", itemTitle: "Keep It Together Headband", itemCount: 1 }]), 1);
  assert.equal(t.relay.setItems("someone-else", [{ brandDomain: "eparaskincare.com", orderName: "#1042", itemTitle: "X" }]), 0, "only the account's own events");
  await t.relay.receive(await rawMail(outForDelivery, address), address.split("@")[0]);
  assert.equal(t.pushes.at(-1).p.aps.alert.body, "Your Keep It Together Headband from Epara Skincare is out for delivery.");
  await t.relay.receive(await rawMail(delivered, address), address.split("@")[0]);
  assert.equal(t.pushes.at(-1).p.aps.alert.body, "Your Keep It Together Headband from Epara Skincare was delivered.");
});

test("one Delivered per order, however many records and updates there are (KOBA, 2026-10-09)", async () => {
  const t = setup();
  t.db.prepare("INSERT INTO restock_devices(hash,token,environment,updated) VALUES('dev','ab','production',0)").run();
  const { address } = t.relay.register("google:1", "dev");
  const local = address.split("@")[0];
  // A shipping email and an out-for-delivery email for the same package: two records, one tracker.
  await t.relay.receive(await rawMail(shipped, address), local);
  await t.relay.receive(await rawMail({ ...outForDelivery, html: shipped.html }, address), local);
  const trackers = t.db.prepare("SELECT DISTINCT tracker_id FROM relay_events WHERE tracker_id IS NOT NULL").all();
  assert.equal(trackers.length, 1);
  const before = t.pushes.length;
  const delivered = { event: "TRACKING_UPDATED", data: { number: trackers[0].tracker_id, track_info: { latest_status: { status: "Delivered" } } } };
  await t.relay.track17Update(delivered);
  await t.relay.track17Update(delivered); // the 10-minute poll sees it again
  await t.relay.receive(await rawMail(delivered === null ? shipped : { subject: "A shipment from order #1042 has been delivered", fromName: "Epara Skincare", fromAddress: "hello@eparaskincare.com", html: "", text: "Your package was delivered." }, address), local);
  const deliveredPushes = t.pushes.slice(before).filter((x) => x.p.aps.alert.title === "Delivered");
  assert.equal(deliveredPushes.length, 1, "the brand's delivered email doesn't repeat the carrier's");
});

test("USPS, UPS and OnTrac go to EasyPost, FedEx and unknowns to 17TRACK; one key alone takes every number", async () => {
  const took = [];
  const fake = (service, id) => Object.assign(async (s) => { took.push([service, s.trackingNumber]); return { id: id(s) }; }, { service, costUSD: 0.03 });
  const usps = fake("EasyPost", () => "trk_1"), rest = fake("17TRACK", (s) => s.trackingNumber);
  const track = trackerFor({}, { usps, rest });
  assert.deepEqual(await track({ trackingNumber: "9400111899223197428490", carrier: "USPS" }), { service: "EasyPost", id: "trk_1" });
  assert.deepEqual(await track({ trackingNumber: "1Z999AA10123456784", carrier: "UPS" }), { service: "EasyPost", id: "trk_1" });
  assert.deepEqual(await track({ trackingNumber: "1LSD0VW001F9GHU", carrier: "OnTrac" }), { service: "EasyPost", id: "trk_1" });
  assert.deepEqual(await track({ trackingNumber: "771234567890", carrier: "FedEx" }), { service: "17TRACK", id: "771234567890" });
  await track({ trackingNumber: "LX123456789", carrier: null });
  assert.deepEqual(took.map(([s]) => s), ["EasyPost", "EasyPost", "EasyPost", "17TRACK", "17TRACK"], "an unknown carrier stays with 17TRACK's auto-detection");
  // EasyPost refusing a number hands it to 17TRACK.
  const refusing = Object.assign(async () => { throw new Error("EasyPost 422"); }, { service: "EasyPost", costUSD: 0.03 });
  assert.deepEqual(await trackerFor({}, { usps: refusing, rest })({ trackingNumber: "1Z1", carrier: "UPS" }), { service: "17TRACK", id: "1Z1" });
  assert.equal(trackerFor({}, { usps: null, rest }), rest);
  assert.equal(trackerFor({}, { usps, rest: null }), usps);
  assert.equal(trackerFor({}, { usps: null, rest: null }), null);
  assert.equal(trackerFor({ TRACK17_API_KEY: "k" }).service, "17TRACK");
  assert.equal(trackerFor({ TRACK17_API_KEY: "k", EASYPOST_API_KEY: "e" }).service, "17TRACK/EasyPost");
});

test("the tracking webhooks refuse unsigned pushes and hand signed ones to the order-page listeners", async () => {
  const { relayRoutes } = await import("../server/relay.js");
  const express = (await import("express")).default;
  const { db, relay } = setup();
  const heard = { easypost: [], track17: [] };
  const app = express();
  relayRoutes(app, db, relay, { env: { EASYPOST_WEBHOOK_SECRET: "s3cret", TRACK17_API_KEY: "k17" },
    easypost: [async (p) => heard.easypost.push(p)], track17: [async (p) => heard.track17.push(p)] });
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  const base = `http://127.0.0.1:${server.address().port}/api/relay`;
  try {
    const ep = JSON.stringify({ description: "tracker.updated", result: { id: "trk_9", status: "in_transit" } });
    const epSig = "hmac-sha256-hex=" + createHmac("sha256", "s3cret").update(ep).digest("hex");
    assert.equal((await fetch(`${base}/easypost`, { method: "POST", body: ep })).status, 401, "no signature");
    assert.equal((await fetch(`${base}/easypost`, { method: "POST", body: ep, headers: { "X-Hmac-Signature": epSig.replace(/.$/, "0") } })).status, 401);
    assert.equal((await fetch(`${base}/easypost`, { method: "POST", body: ep, headers: { "X-Hmac-Signature": epSig } })).status, 200);
    assert.deepEqual(heard.easypost.map((p) => p.result.id), ["trk_9"]);

    const t17 = JSON.stringify({ event: "TRACKING_UPDATED", data: { number: "1ZX", track_info: {} } });
    const t17Sig = createHash("sha256").update(t17 + "/k17").digest("hex");
    assert.equal((await fetch(`${base}/17track`, { method: "POST", body: t17, headers: { sign: "0".repeat(64) } })).status, 401);
    assert.equal((await fetch(`${base}/17track`, { method: "POST", body: t17, headers: { sign: t17Sig } })).status, 200);
    assert.deepEqual(heard.track17.map((p) => p.data.number), ["1ZX"]);
    assert.equal(heard.easypost.length, 1, "a 17TRACK push never reaches the EasyPost listeners");
  } finally { server.close(); }
});

// Owner, 2026-10-13: RIPL EFEK shipped #1417 by OnTrac (1LS… numbers).
test("OnTrac numbers are read from ontrac.com links and bare in tracking emails, and typed numbers get their carrier", () => {
  assert.deepEqual(findTracking('<a href="https://www.ontrac.com/tracking/?number=1LSD0VW001F9GHU">Track</a>'),
    { carrier: "OnTrac", trackingNumber: "1LSD0VW001F9GHU" });
  assert.deepEqual(findTracking('<a href="https://www.ontrac.com/trackingresults.asp?tracking_number=C11422907414950">x</a>'),
    { carrier: "OnTrac", trackingNumber: "C11422907414950" });
  assert.deepEqual(findTracking("", "Your tracking number is 1LSD0VW001F9GHU"), { carrier: "OnTrac", trackingNumber: "1LSD0VW001F9GHU" });
  const shipped = parseOrderEmail({ subject: "Your order #1417 is on the way", html: '<p>OnTrac tracking number: <a href="https://www.ontrac.com/tracking/?number=1LSD0VW001F9GHU">1LSD0VW001F9GHU</a></p>' });
  assert.equal(shipped.kind, "shipped");
  assert.equal(shipped.carrier, "OnTrac");
  assert.equal(carrierFor("1LSD0VW001F9GHU"), "OnTrac");
  assert.equal(carrierFor("1Z999AA10123456784"), "UPS");
  assert.equal(carrierFor("9400111899223197428490"), "USPS");
  assert.equal(carrierFor("123456789012"), "FedEx");
  assert.equal(carrierFor("XYZ123"), null);
  assert.equal(TRACK17_CARRIERS.OnTrac, 100049, "17TRACK's OnTrac carrier code (apicarrier.all.json)");
});

// The carrier's own words for a problem (owner, 2026-10-21): kept for the
// app's explanation, from either tracking service.
import { detailFrom17Track, detailFromEasyPost } from "../server/relay.js";
test("the carrier's last words are kept, clipped and plain", () => {
  assert.equal(detailFrom17Track({ latest_event: { description: "  Delivery attempted -\n no access to delivery location " } }),
    "Delivery attempted - no access to delivery location");
  assert.equal(detailFrom17Track({ latest_event: {}, latest_status: { sub_status_descr: "Address issue" } }), "Address issue");
  assert.equal(detailFrom17Track(null), null);
  assert.equal(detailFromEasyPost({ tracking_details: [{ message: "Shipped" }, { message: "Return to sender processed" }] }), "Return to sender processed");
  assert.equal(detailFromEasyPost({ tracking_details: [], status_detail: "address_not_found" }), "address not found");
  assert.equal(detailFromEasyPost({}), null);
  assert.equal(detailFrom17Track({ latest_event: { description: "x".repeat(300) } }).length, 200);
});

// 2026-11-12: an email's order link was stored whatever it was.
test("an order link is kept only over https, on the brand's own site or Shopify's", async () => {
  const { provenance } = await import("../server/relay.js");
  assert.equal(parseOrderEmail({ subject: "Your order is on the way", html: `<a href="${STATUS.replace("https:", "http:")}">View your order</a>` }).statusURL, null, "cleartext link");
  assert.equal(parseOrderEmail({ subject: "Your order is on the way", html: `<a href="${STATUS}">View your order</a>` }).statusURL, STATUS);
  const t = setup();
  const { address } = t.relay.register("google:1", "dev");
  const elsewhere = { ...shipped, html: shipped.html.replaceAll("eparaskincare.com", "evil.example") };
  const e = await t.relay.receive(await rawMail(elsewhere, address), address.split("@")[0]);
  assert.equal(t.db.prepare("SELECT status_url FROM relay_events WHERE id=?").get(e.id).status_url, null, "a brand's mail linking to another site");
  const own = await t.relay.receive(await rawMail(shipped, address), address.split("@")[0]);
  assert.equal(t.db.prepare("SELECT status_url FROM relay_events WHERE id=?").get(own.id).status_url, STATUS);
  assert.equal(provenance("eparaskincare.com"), "eparaskincare.com; sender verified");
  assert.equal(provenance(null), "unknown sender");
});
