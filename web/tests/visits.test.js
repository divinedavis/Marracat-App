import { test } from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { installVisitSchema, recordVisit, refHost, localDay, farmWatch, netOf, FARM_IPS, FARM_MEMORY_DAYS,
  labelVisitor, labelOf, isOwnerVisitor, installLabelSchema } from "../server/visits.js";
import { createHash } from "node:crypto";
import express from "express";
import { visitRoutes } from "../server/visits.js";
import { isDatacenter } from "../server/datacenter.js";
import { installEventSchema, recordEvent } from "../server/events.js";

// One row per visitor per day; where they came from only on their first visit.
test("visits: one row a day, first visit keeps the source, ids are hashed", () => {
  const db = new Database(":memory:");
  installVisitSchema(db);
  const day1 = Date.UTC(2026, 9, 4, 15), day2 = Date.UTC(2026, 9, 5, 15);
  recordVisit(db, { visitor: "abcdefghijklmnop1", platform: "web", ref: "https://www.tiktok.com/@x", src: "tt", now: day1 });
  recordVisit(db, { visitor: "abcdefghijklmnop1", platform: "web", ref: "https://google.com", now: day1 });
  recordVisit(db, { visitor: "abcdefghijklmnop1", platform: "web", ref: "https://google.com", userID: "u1", now: day2 });
  const rows = db.prepare("SELECT * FROM visits ORDER BY day").all();
  assert.equal(rows.length, 2);
  assert.deepEqual([rows[0].first, rows[0].ref_host, rows[0].src], [1, "tiktok.com", "tt"]);
  assert.deepEqual([rows[1].first, rows[1].ref_host, rows[1].user_id], [0, null, "u1"]);
  assert.notEqual(rows[0].visitor, "abcdefghijklmnop1");
});

test("own pages aren't a referrer; days are New York days", () => {
  assert.equal(refHost("https://marracat.com/#/shop"), "");
  assert.equal(refHost("not a url"), "");
  assert.equal(refHost("https://l.instagram.com/x"), "l.instagram.com");
  assert.equal(localDay(Date.UTC(2026, 9, 5, 2)), "2026-10-04", "10 pm in New York is still the 4th");
});

// 2026-10-24: Leaseweb sent one visit from each of ~47 addresses in one block.
test("a block of addresses with one browser is a bot farm, and its earlier visits go too", () => {
  const db = new Database(":memory:");
  installVisitSchema(db);
  const isFarm = farmWatch(db), now = Date.UTC(2026, 9, 24, 15), ua = "Mozilla/5.0 (X11; Linux x86_64) Chrome/145.0.0.0";
  for (let i = 1; i < FARM_IPS; i++) {
    const id = `farmvisitor000000${i}`;
    assert.equal(isFarm(`152.163.233.${i}`, ua, id, now), false);
    recordVisit(db, { visitor: id, platform: "web", now });
  }
  assert.equal(db.prepare("SELECT count(*) n FROM visits").get().n, FARM_IPS - 1);
  assert.equal(isFarm("152.163.233.99", ua, "farmvisitor0000099", now), true, "the fifth address makes it a farm");
  assert.equal(db.prepare("SELECT count(*) n FROM visits").get().n, 0, "its earlier visits are removed");
  // A household: two phones on one network, or one address all day, still count.
  recordVisit(db, { visitor: "homevisitor000001", platform: "web", now });
  assert.equal(isFarm("71.190.10.4", "Safari iPhone", "homevisitor000001", now), false);
  assert.equal(isFarm("71.190.10.5", "Safari Mac", "homevisitor000002", now), false);
  assert.equal(isFarm("71.190.10.4", "Safari iPhone", "homevisitor000001", now), false);
  assert.equal(netOf("::ffff:152.163.233.7"), "152.163.233");
});

// 2026-10-29: 205.188.100.0/24 was out of the visit count but read as 35 of
// 41 web people in the event report.
test("a farm's earlier events go too; phones and other visitors stay", () => {
  const db = new Database(":memory:");
  installVisitSchema(db);
  installEventSchema(db);
  const isFarm = farmWatch(db), now = Date.UTC(2026, 9, 29, 15), ua = "Mozilla/5.0 (X11; Linux x86_64) Chrome/145.0.0.0";
  const open = { name: "product_open", product: "epara-skincare-1", platform: "web" };
  recordEvent(db, "shoppervisitor001", open, now);
  recordEvent(db, "phonevisitor00001", { ...open, platform: "ios" }, now);
  for (let i = 1; i < FARM_IPS; i++) {
    const id = `farmvisitor000000${i}`;
    assert.equal(isFarm(`205.188.100.${i}`, ua, id, now), false);
    recordEvent(db, id, open, now);
  }
  assert.equal(isFarm("205.188.100.99", ua, "farmvisitor0000099", now), true);
  const left = db.prepare("SELECT platform FROM site_events ORDER BY platform").all().map((r) => r.platform);
  assert.deepEqual(left, ["ios", "web"], "only the farm's web events are removed");
});

// 2026-11-04: the watcher lived only in memory, so each of 22 deploys on
// 11/3–4 let every farm block back in for four addresses (66 of 95 web people).
test("a farm block is remembered across a restart, and forgotten after a quiet month", () => {
  const db = new Database(":memory:");
  installVisitSchema(db);
  const ua = "Mozilla/5.0 (X11; Linux x86_64) Chrome/145.0.0.0", now = Date.UTC(2026, 10, 3, 15);
  const first = farmWatch(db);
  for (let i = 1; i <= FARM_IPS; i++) first(`152.163.233.${i}`, ua, `farmvisitor000000${i}`, now);
  const stored = db.prepare("SELECT net, ua FROM farm_blocks").all();
  assert.equal(stored.length, 1);
  assert.equal(stored[0].net, "152.163.233", "only the /24 is kept, never an address");
  assert.notEqual(stored[0].ua, ua, "the browser string is hashed");

  const restarted = farmWatch(db), tomorrow = now + 86_400_000;
  assert.equal(restarted("152.163.233.200", ua, "farmvisitor0000200", tomorrow), true, "refused from the first request");
  assert.equal(restarted("152.163.233.201", "Safari iPhone", "homevisitor000003", tomorrow), false, "another browser on that block still counts");
  assert.equal(restarted("71.190.10.4", ua, "homevisitor000004", tomorrow), false, "that browser elsewhere still counts");

  const later = tomorrow + (FARM_MEMORY_DAYS + 1) * 86_400_000;
  assert.equal(farmWatch(db)("152.163.233.200", ua, "farmvisitor0000300", later), false, "a month after it was last seen, it starts over");
});

// 2026-11-09: the owner's signed-out Mac browser read as a returning visitor,
// and a creator's demo shopping read as a stranger's.
test("labels: an owner label removes that visitor's rows; a creator label keeps them", () => {
  const db = new Database(":memory:");
  installVisitSchema(db);
  installEventSchema(db);
  const now = Date.UTC(2026, 10, 9, 15);
  const hash = (v) => createHash("sha256").update(v).digest("hex");
  for (const v of ["ownerbrowser00000001", "creatorphone00000001"]) {
    recordVisit(db, { visitor: v, platform: "web", now });
    recordEvent(db, v, { name: "search", q: "pants", platform: "web" }, now);
  }
  assert.deepEqual(labelVisitor(db, hash("ownerbrowser00000001"), "owner", "Divine's Mac", now), { visits: 1, site_events: 1 });
  assert.deepEqual(labelVisitor(db, hash("creatorphone00000001"), "creator", "Kaila", now), { visits: 0, site_events: 0 });
  assert.equal(db.prepare("SELECT count(*) n FROM visits").get().n, 1);
  assert.equal(db.prepare("SELECT count(*) n FROM site_events").get().n, 1);
  assert.equal(isOwnerVisitor(db, "ownerbrowser00000001"), true);
  assert.deepEqual(labelOf(db, "creatorphone00000001"), { kind: "creator", name: "Kaila" });
  assert.equal(labelOf(db, "someoneelse000000001"), null);
  assert.throws(() => labelVisitor(db, "not-a-hash", "owner"));
  assert.throws(() => labelVisitor(db, hash("x"), "friend"));
  installLabelSchema(db);  // idempotent
});

// 2026-11-12: one crawler, eight cloud addresses (Tencent Cloud, Huawei
// Cloud), one brand page each in four minutes, read as the day's 8 web
// visitors. The visit count now refuses server networks, as the log count did.
test("server networks aren't visitors: prefixes and CIDR blocks, IPv4-mapped too", () => {
  for (const ip of ["119.28.133.79", "49.233.119.168", "116.204.0.225", "43.130.13.194", "43.156.153.86",
    "159.138.93.101", "46.250.169.157", "::ffff:119.28.133.79", "3.5.6.7"]) assert.ok(isDatacenter(ip), ip);
  for (const ip of ["74.105.101.195", "109.208.85.129", "2600:1700::1", "", undefined]) assert.ok(!isDatacenter(ip), String(ip));
});

test("/api/visit records a home browser and skips one on a server network; the app is never judged by address", async (t) => {
  const db = new Database(":memory:");
  const app = express();
  app.set("trust proxy", "loopback");
  visitRoutes(app, db);
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => { s.close(); db.close(); });
  const BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36";
  const visit = (ip, id, ua = BROWSER, headers = {}) => fetch(`http://127.0.0.1:${s.address().port}/api/visit`, {
    method: "POST", headers: { "Content-Type": "application/json", "User-Agent": ua, "X-Forwarded-For": ip, ...headers },
    body: JSON.stringify({ id }),
  });
  const rows = () => db.prepare("SELECT platform FROM visits ORDER BY platform").all().map((r) => r.platform);
  assert.equal((await visit("119.28.133.79", "crawler000000000001")).status, 204);
  assert.deepEqual(rows(), []);
  assert.equal((await visit("74.105.101.195", "shopper000000000001")).status, 204);
  assert.deepEqual(rows(), ["web"]);
  // A phone on a carrier that NATs through a cloud block still counts.
  await visit("3.5.6.7", "ignored", "Marracat/185 channel/appstore iOS/26.1", { "X-Marracat-Device": "device00000000000001" });
  assert.deepEqual(rows(), ["ios", "web"]);
});
