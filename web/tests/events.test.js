import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { eventRoutes, cleanEvent, cleanQuery, eventReport, pruneEvents, recordEvent, KEEP_DAYS, BATCH_MAX, recRowReport,
  inAppSession, SESSION_GAP_MS, SCHEMAS, EVENT_NAMES, bucket, userHash, DURATION_EDGES } from "../server/events.js";
import { readFileSync } from "node:fs";
import { installVisitSchema, recordVisit, notAPerson, labelVisitor } from "../server/visits.js";
import { createHash } from "node:crypto";
import { buyClickFor, screenFor, checkoutProps } from "../src/events.js";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const ID = "0123456789abcdef-visitor";
// A real iPhone on iOS 26 (Safari freezes the OS at 18_6).
const BROWSER = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";

async function server(t, { limit, perMinute } = {}) {
  const db = new Database(":memory:");
  const app = express();
  app.set("trust proxy", "loopback");
  eventRoutes(app, db, {
    limit,
    perMinute,
    env: { OWNER_EMAILS: "owner@example.test" },
    viewer: async (req) => (req.get("X-Test-User") ? { id: "u", email: req.get("X-Test-User") } : null),
    appViewer: (req) => (req.get("X-Test-App-User") ? { id: "a", email: req.get("X-Test-App-User") } : null),
  });
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => { s.close(); db.close(); });
  const post = (body, headers = {}) => fetch(`http://127.0.0.1:${s.address().port}/api/events`, {
    method: "POST", headers: { "Content-Type": "application/json", "User-Agent": BROWSER, ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
  return { db, post, count: () => db.prepare("SELECT COUNT(*) n FROM site_events").get().n };
}

test("events outside the allow-list, or missing what they need, are refused", () => {
  assert.equal(cleanEvent({ e: "page_view", product: "a-1" }), null);
  assert.equal(cleanEvent({ e: "product_open" }), null, "a product open needs its product");
  assert.equal(cleanEvent({ e: "buy_click", brand: "koba" }), null, "a Buy click needs how it left");
  assert.equal(cleanEvent({ e: "buy_click", brand: "koba", via: "somewhere" }), null);
  assert.equal(cleanEvent({ e: "product_open", product: "<script>" }), null);
  assert.deepEqual(cleanEvent({ e: "buy_click", brand: "KOBA", via: "cart", product: "koba-1" }),
    { name: "buy_click", q: null, n: null, product: "koba-1", brand: "koba", via: "cart", row: null, position: null, platform: "web", props: null });
});

test("searches are trimmed, bounded and never keep an email or a long number", () => {
  assert.equal(cleanQuery("  Shea   BUTTER "), "shea butter");
  assert.equal(cleanQuery("x".repeat(200)).length, 80);
  assert.equal(cleanQuery("me@example.com"), null);
  assert.equal(cleanQuery("order 4111 1111 1111 1111"), null);
  assert.equal(cleanQuery("718-555-0100"), null);
  assert.equal(cleanQuery("size 10 sweatpants"), "size 10 sweatpants");
  assert.equal(cleanEvent({ e: "search", q: "  " }), null);
  assert.deepEqual(cleanEvent({ e: "search", q: "Parfum", n: 12 }).q, "parfum");
});

test("the endpoint stores a hashed visitor, never the IP, and skips the app, bots and the owner", async (t) => {
  const { db, post, count } = await server(t);
  assert.equal((await post({ id: ID, e: "product_open", product: "koba-1", brand: "koba" })).status, 204);
  const row = db.prepare("SELECT * FROM site_events").get();
  assert.notEqual(row.visitor, ID);
  assert.match(row.visitor, /^[a-f0-9]{64}$/);
  assert.ok(!Object.values(row).some((v) => String(v).includes("127.0.0.1")), "no IP in the row");
  assert.equal((await post({ id: ID, e: "search", q: "candle" }, { "User-Agent": "Marracat/126 channel/appstore iOS/18" })).status, 400,
    "the app identifies itself with X-Marracat-Device, not a body id");
  assert.equal((await post({ id: ID, e: "search", q: "candle" }, { "User-Agent": "Mozilla/5.0 (compatible; Googlebot/2.1)" })).status, 204);
  assert.equal((await post({ id: ID, e: "search", q: "candle" }, { "X-Test-User": "owner@example.test" })).status, 204);
  assert.equal(count(), 1, "only the shopper's event was kept");
  assert.equal((await post({ id: "short", e: "search", q: "candle" })).status, 400);
  assert.equal((await post({ id: ID, e: "nope" })).status, 400);
  assert.equal((await post(JSON.stringify({ id: ID, e: "search", q: "x".repeat(30_000) }))).status, 413, "24 kB body cap (a batch of 50 events fits)");
});

test("a browser on a server network isn't a shopper: its events are skipped, the app's are kept", async (t) => {
  const { post, count } = await server(t);
  // 2026-11-12: a headless crawler on Tencent Cloud ran the storefront's scripts.
  assert.equal((await post({ id: ID, e: "search", q: "candle" }, { "X-Forwarded-For": "119.28.133.79" })).status, 204);
  assert.equal(count(), 0);
  assert.equal((await post({ id: ID, e: "search", q: "candle" }, { "X-Forwarded-For": "74.105.101.195" })).status, 204);
  assert.equal(count(), 1, "a home broadband address counts");
});

test("our own Playwright journeys never count: headless Chrome and its iPhone emulation user agents", async (t) => {
  const { post, count } = await server(t);
  for (const ua of [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/155.0.0.0 Safari/537.36",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/129.0 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6 Mobile/15E148 Safari/604.1",
  ]) assert.equal((await post({ id: ID, e: "search", q: "socks" }, { "User-Agent": ua })).status, 204, ua);
  assert.equal(count(), 0);
  for (const ua of [BROWSER, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1"])
    assert.equal((await post({ id: ID, e: "search", q: "socks" }, { "User-Agent": ua })).status, 204, ua);
  assert.equal(count(), 2, "real iPhones still count");
  assert.ok(!notAPerson("Marracat/137 channel/testflight iOS/27.0"));
});

test("Xcode and simulator builds (channel/debug) are never counted; TestFlight and App Store builds are", async (t) => {
  const { post, count } = await server(t);
  const app = (channel) => ({ "User-Agent": `Marracat/137 channel/${channel} iOS/26.3`, "X-Marracat-Device": "a".repeat(64) });
  assert.equal((await post({ name: "list_create" }, app("debug"))).status, 204);
  assert.equal(count(), 0);
  assert.equal((await post({ name: "list_create" }, app("testflight"))).status, 204);
  assert.equal((await post({ name: "list_create" }, app("appstore"))).status, 204);
  assert.equal(count(), 2);
});

test("sendBeacon's Blob is read as JSON whatever its content type", async (t) => {
  const { post, count } = await server(t);
  assert.equal((await post({ id: ID, e: "add_to_cart", product: "koba-1" }, { "Content-Type": "text/plain;charset=UTF-8" })).status, 204);
  assert.equal(count(), 1);
});

test("one address is rate-limited", async (t) => {
  const { post } = await server(t, { limit: 3 });
  const codes = [];
  for (let i = 0; i < 5; i++) codes.push((await post({ id: ID, e: "search", q: "soap" })).status);
  assert.deepEqual(codes, [204, 204, 204, 429, 429]);
});

test("old events are pruned after 180 days", () => {
  const db = new Database(":memory:");
  const app = express();
  eventRoutes(app, db);
  const now = Date.now();
  recordEvent(db, ID, cleanEvent({ e: "search", q: "old" }), now - (KEEP_DAYS + 1) * 86_400_000);
  recordEvent(db, ID, cleanEvent({ e: "search", q: "new" }), now);
  assert.equal(pruneEvents(db, now), 1);
  assert.deepEqual(db.prepare("SELECT q FROM site_events").all().map((r) => r.q), ["new"]);
});

test("the weekly report has top searches, the funnel, Buy clicks by brand and returning visitors", () => {
  const db = new Database(":memory:");
  eventRoutes(express(), db);
  installVisitSchema(db);
  const now = Date.parse("2026-10-10T16:00:00Z");
  const ev = (who, body) => recordEvent(db, who, cleanEvent(body), now);
  ev("a".repeat(20), { e: "search", q: "shea butter", n: 40 });
  ev("b".repeat(20), { e: "search", q: "Shea Butter", n: 40 });
  ev("b".repeat(20), { e: "search", q: "zzz", n: 0 });
  ev("a".repeat(20), { e: "product_open", product: "koba-1" });
  ev("b".repeat(20), { e: "product_open", product: "koba-1" });
  ev("a".repeat(20), { e: "add_to_cart", product: "koba-1" });
  ev("a".repeat(20), { e: "buy_click", brand: "koba", via: "cart" });
  recordVisit(db, { visitor: "a".repeat(20), platform: "web", now: now - 86_400_000 });
  recordVisit(db, { visitor: "a".repeat(20), platform: "web", now });
  recordVisit(db, { visitor: "c".repeat(20), platform: "ios", now });
  const r = eventReport(db, { days: 7, now });
  assert.deepEqual(r.searches[0], { q: "shea butter", searches: 2, visitors: 2, no_results: 0 });
  assert.equal(r.searches.find((s) => s.q === "zzz").no_results, 1);
  assert.deepEqual(
    [r.funnel.searched, r.funnel.opened_a_product, r.funnel.added_to_cart, r.funnel.clicked_buy], [2, 2, 1, 1]);
  assert.deepEqual(r.buy_clicks_by_brand, [{ brand: "koba", clicks: 1, visitors: 1 }]);
  assert.deepEqual(r.visitors, { web_visitors: 1, returning_from_before: 1, came_back_on_2plus_days: 1 });
});

test("Buy links are recognised: Shopify cart, Big Cartel, a brand's own page; not other sites", () => {
  const hosts = new Map([["kobaskin.com", "koba"], ["fearofgod.com", "fear-of-god"]]);
  const brand = (h) => hosts.get(h);
  const here = "https://marracat.com";
  assert.deepEqual(buyClickFor("https://kobaskin.com/cart/123:1,456:2?currency=USD", brand, here), { brand: "koba", via: "cart" });
  assert.deepEqual(buyClickFor("https://www.fearofgod.com/products/tee", brand, here), { brand: "fear-of-god", via: "brand_site" });
  assert.deepEqual(buyClickFor("/go/bigcartel?brand=ama&items=a:1:1", brand, here), { brand: "ama", via: "bigcartel" });
  assert.equal(buyClickFor("/p/koba-1", brand, here), null);
  assert.equal(buyClickFor("https://instagram.com/koba", brand, here), null);
  assert.equal(buyClickFor("javascript:alert(1)", brand, here), null);
});

// Recommendation rows (owner, 2026-10-10: measure whether recommendations work).
const APP = "Marracat/127 channel/testflight iOS/26.6";
const DEVICE = "6F1C2A9E-3B4D-4E5F-8A7B-9C0D1E2F3A4B";

test("row events need an allow-listed row; other fields are bounded", () => {
  assert.equal(cleanEvent({ name: "rec_view", row: "search" }).row, "search");
  assert.equal(cleanEvent({ e: "rec_tap", row: "pairs", product: "koba-1", position: 3 }).position, 3);
  assert.equal(cleanEvent({ name: "rec_view" }), null, "row required");
  for (const row of ["Search", "1row", "a b", "x".repeat(42), "<script>"]) assert.equal(cleanEvent({ name: "rec_view", row }), null, row);
  assert.equal(cleanEvent({ name: "rec_view", row: "taste", position: 5000 }).position, null);
  assert.equal(cleanEvent({ name: "rec_view", row: "taste", platform: "android" }).platform, "web");
  assert.equal(cleanEvent({ name: "rec_view", row: "taste", platform: "ios" }).platform, "ios");
  assert.equal(cleanEvent({ name: "rec_view", row: "taste" }, "ios").platform, "ios");
});

test("the app's events are stored under a hashed device id with its build", async (t) => {
  const { db, post, count } = await server(t);
  const app = { "User-Agent": APP, "X-Marracat-Device": DEVICE };
  assert.equal((await post({ events: [{ name: "app_open" }, { name: "rec_view", row: "search", product: "koba-1", position: 0 }] }, app)).status, 204);
  const row = db.prepare("SELECT * FROM site_events WHERE name='rec_view'").get();
  assert.equal(row.platform, "ios");
  assert.equal(row.row, "search");
  assert.match(row.visitor, /^[a-f0-9]{64}$/);
  assert.ok(!Object.values(row).some((v) => String(v).includes(DEVICE)), "the raw device id is never stored");
  assert.equal((await post({ name: "search", q: "candle", source: "typed" }, app)).status, 204, "the app's other events count too");
  assert.equal(count(), 3);
  assert.equal(db.prepare("SELECT platform, build FROM site_events WHERE name='search'").get().build, "127", "build from the app's User-Agent");
  assert.equal((await post({ name: "rec_view", row: "search" }, { "User-Agent": APP })).status, 400, "no device id");
  assert.equal((await post({ name: "rec_view", row: "Bad Row" }, app)).status, 400);
});

test("a batch of up to 50 rows is one request; bigger batches and empty ones are refused", async (t) => {
  const { post, count } = await server(t);
  const app = { "User-Agent": APP, "X-Marracat-Device": DEVICE };
  assert.equal((await post({ name: "app_open" }, app)).status, 204);
  const events = Array.from({ length: BATCH_MAX }, (_, i) => ({ name: "rec_view", row: "taste", product: `p-${i}`, position: i }));
  assert.equal((await post({ events }, app)).status, 204);
  assert.equal(count(), 1 + BATCH_MAX);
  assert.equal((await post({ events: [...events, events[0]] }, app)).status, 400);
  assert.equal((await post({ events: [] }, app)).status, 400);
  // A mixed batch keeps the valid events and drops the rest.
  assert.equal((await post({ events: [{ name: "rec_tap", row: "taste" }, { name: "search", q: "soap" }, { name: "page_view" }] }, app)).status, 204);
  assert.equal(count(), 1 + BATCH_MAX + 2);
});

test("the owner's phone is skipped, by account or by today's address", async (t) => {
  const { db, post, count } = await server(t);
  const app = { "User-Agent": APP, "X-Marracat-Device": DEVICE };
  assert.equal((await post({ name: "app_open" }, { ...app, "X-Test-App-User": "owner@example.test" })).status, 204);
  assert.equal(count(), 0);
  db.exec("CREATE TABLE owner_sightings (day TEXT NOT NULL, ip TEXT NOT NULL, PRIMARY KEY(day, ip))");
  db.prepare("INSERT INTO owner_sightings VALUES(?, ?)").run(new Date().toISOString().slice(0, 10), "127.0.0.1");
  assert.equal((await post({ name: "app_open" }, app)).status, 204);
  assert.equal(count(), 0, "the owner's address today");
});

test("the owner's signed-out browser is skipped, by label or by today's address; creators are counted and named", async (t) => {
  const { db, post, count } = await server(t);
  const hash = (v) => createHash("sha256").update(v).digest("hex");
  db.exec("CREATE TABLE owner_sightings (day TEXT NOT NULL, ip TEXT NOT NULL, PRIMARY KEY(day, ip))");
  labelVisitor(db, hash("ownermacbrowser-0001"), "owner", "Mac");
  assert.equal((await post({ id: "ownermacbrowser-0001", e: "search", q: "pants" })).status, 204);
  assert.equal(count(), 0, "labelled owner browser");
  labelVisitor(db, hash(ID), "creator", "Kaila");
  assert.equal((await post({ id: ID, e: "product_open", product: "styl-charm-1", brand: "styl-charm" })).status, 204);
  assert.equal(count(), 1, "a creator is still counted");
  const known = eventReport(db, { days: 7 }).known_people;
  assert.deepEqual(known.map((k) => [k.kind, k.name, k.product_views]), [["creator", "Kaila", 1]]);
  db.prepare("INSERT INTO owner_sightings VALUES(?, ?)").run(new Date().toISOString().slice(0, 10), "127.0.0.1");
  assert.equal((await post({ id: "anotherbrowser-00001", e: "search", q: "pants" })).status, 204);
  assert.equal(count(), 1, "a website visit from the owner's address today");
});

test("batches can't get past the per-address event budget", async (t) => {
  const { post, count } = await server(t, { perMinute: 60 });
  const app = { "User-Agent": APP, "X-Marracat-Device": DEVICE };
  const events = [{ name: "app_open" }, ...Array.from({ length: 39 }, () => ({ name: "rec_view", row: "taste" }))];
  assert.equal((await post({ events }, app)).status, 204);
  assert.equal((await post({ events }, app)).status, 429);
  assert.equal(count(), 40);
});

test("the report gives views, taps, tap rate and people per row and platform; the web funnel ignores rows", () => {
  const db = new Database(":memory:");
  eventRoutes(express(), db);
  const now = Date.now();
  for (const v of ["a".repeat(20), "b".repeat(20)]) recordEvent(db, v, cleanEvent({ name: "rec_view", row: "search" }, "ios"), now);
  recordEvent(db, "a".repeat(20), cleanEvent({ name: "rec_tap", row: "search" }, "ios"), now);
  recordEvent(db, "c".repeat(20), cleanEvent({ name: "rec_view", row: "complements", platform: "web" }), now);
  recordEvent(db, "d".repeat(20), cleanEvent({ name: "rec_view", row: "search" }, "ios"), now - 20 * 86_400_000);
  const week = recRowReport(db, { days: 7, now });
  assert.deepEqual(week.find((r) => r.row === "search"), { row: "search", platform: "ios", views: 2, taps: 1, visitors: 2, tap_rate: 0.5 });
  assert.equal(week.find((r) => r.row === "complements").platform, "web");
  assert.equal(recRowReport(db, { days: 30, now }).find((r) => r.row === "search").views, 3, "30 days includes the older view");
  const report = eventReport(db, { days: 7, now });
  assert.equal(report.recommendation_rows.last_7_days.length, 2);
  assert.equal(report.funnel.visitors_with_any_event, 0, "rows aren't funnel visitors");
});

// The full event catalog (owner, 2026-10-10: "make our analytics more robust").
test("every event in the catalog has a schema and is documented in EVENTS.md", () => {
  const doc = readFileSync(new URL("../server/EVENTS.md", import.meta.url), "utf8");
  for (const name of EVENT_NAMES) assert.match(doc, new RegExp("`" + name + "`"), `${name} missing from EVENTS.md`);
  for (const name of ["app_open", "session_end", "screen_view", "product_view", "filter_apply", "save", "unsave", "brand_follow",
    "brand_unfollow", "alert_on", "alert_off", "remove_from_cart", "checkout_start", "checkout_complete", "checkout_abandon", "share",
    "comment_post", "notification_open", "sign_in_start", "sign_in_complete", "sign_up_complete", "sign_in_cancel", "sign_in_fail", "label_sheet_open", "gallery_open",
    "gallery_zoom", "list_create", "list_add", "brand_instagram"]) assert.ok(SCHEMAS[name], name);
});

// Search's Featured banner (owner, 2026-10-12).
test("banner events need the featured_banner kind and a brand id", () => {
  const ok = cleanEvent({ name: "banner_view", kind: "featured_banner", brand: "fenty-beauty", platform: "ios" });
  assert.equal(ok.props.kind, "featured_banner");
  assert.equal(ok.brand, "fenty-beauty");
  assert.equal(cleanEvent({ name: "banner_tap", kind: "featured_banner", brand: "telfar" }).brand, "telfar");
  assert.equal(cleanEvent({ name: "banner_tap", kind: "featured_banner" }), null, "brand required");
  assert.equal(cleanEvent({ name: "banner_view", brand: "telfar" }), null, "kind required");
  assert.equal(cleanEvent({ name: "banner_view", kind: "deals_for_you", brand: "telfar" }), null, "unknown kind");
  assert.equal(cleanEvent({ name: "banner_tap", kind: "featured_banner", brand: "<script>" }), null, "brand by pattern");
});

test("the report counts banner views and taps by brand", async (t) => {
  const { db, post } = await server(t);
  const app = { "User-Agent": APP, "X-Marracat-Device": DEVICE };
  for (const name of ["banner_view", "banner_view", "banner_tap"])
    assert.equal((await post({ name, kind: "featured_banner", brand: "telfar", platform: "ios" }, app)).status, 204);
  const [row] = eventReport(db).banners;
  assert.deepEqual({ ...row }, { kind: "featured_banner", brand: "telfar", views: 2, taps: 1, people: 1 });
});

test("per-event schemas: required props, enums, ids by pattern; unknown props are dropped", () => {
  assert.equal(cleanEvent({ name: "screen_view", screen: "home" }).props.screen, "home");
  assert.equal(cleanEvent({ name: "screen_view", screen: "admin" }), null, "screen allow-list");
  assert.equal(cleanEvent({ name: "screen_view" }), null, "screen required");
  assert.equal(cleanEvent({ name: "alert_on", kind: "price", product: "koba-1" }).props.kind, "price");
  assert.equal(cleanEvent({ name: "alert_on", kind: "weather" }), null);
  assert.equal(cleanEvent({ name: "sign_in_complete", provider: "apple" }).props.provider, "apple");
  assert.equal(cleanEvent({ name: "sign_in_complete", provider: "myspace" }), null);
  // Owner, 2026-11-08: which step a checkout or sign-in stopped at.
  const abandon = cleanEvent({ name: "checkout_abandon", via: "cart", subtotal: 30, step: "shipping", shipping: 7.5 });
  assert.deepEqual(abandon.props, { subtotal: "25-50", step: "shipping", shipping: "5-10" });
  assert.equal(abandon.via, "cart");
  assert.equal(cleanEvent({ name: "checkout_abandon", via: "cart", shipping: 0 }).props.shipping, "0-1", "free shipping");
  assert.equal(cleanEvent({ name: "checkout_abandon", via: "cart", step: "teleport" }).props?.step, undefined, "step allow-list");
  assert.deepEqual(cleanEvent({ name: "sign_in_cancel", provider: "google", step: "provider" }).props, { provider: "google", step: "provider" });
  assert.deepEqual(cleanEvent({ name: "sign_in_fail", provider: "apple", step: "exchange", reason: "network" }).props,
    { provider: "apple", step: "exchange", reason: "network" });
  assert.equal(cleanEvent({ name: "sign_in_fail", step: "exchange" }), null, "needs the provider");
  assert.equal(cleanEvent({ name: "save", product: "<img>" }), null, "ids by pattern");
  assert.equal(cleanEvent({ name: "brand_follow", brand: "KOBA-skincare" }).brand, "koba-skincare");
  assert.equal(cleanEvent({ name: "brand_instagram", brand: "kibonen" }).brand, "kibonen");
  assert.equal(cleanEvent({ name: "brand_instagram" }), null, "needs the brand");
  const e = cleanEvent({ name: "product_view", product: "koba-1", source: "search", dwell_s: 42, secret: "x", email: "a@b.c" });
  assert.deepEqual(e.props, { source: "search", dwell_s: "30-60" });
  assert.equal(e.product, "koba-1");
  assert.equal(cleanEvent({ name: "list_create", title: "My list" }).props, null, "free text dropped");
  // Props may also arrive nested under props.
  assert.equal(cleanEvent({ name: "share", props: { kind: "brand", target: "telfar" } }).props.target, "telfar");
});

test("filters: names and values are both allow-listed", () => {
  assert.equal(cleanEvent({ name: "filter_apply", filter: "clean", value: true }).props.value, "on");
  assert.equal(cleanEvent({ name: "filter_apply", filter: "sort", value: "low" }).props.value, "low");
  assert.equal(cleanEvent({ name: "filter_apply", filter: "sort", value: "cheapest" }), null);
  assert.equal(cleanEvent({ name: "filter_apply", filter: "type", value: "clothing:sweatpants" }).props.value, "clothing:sweatpants");
  assert.equal(cleanEvent({ name: "filter_apply", filter: "brand", value: "fear-of-god" }).props.value, "fear-of-god");
  assert.equal(cleanEvent({ name: "filter_apply", filter: "brand", value: "free text here" }), null);
  assert.equal(cleanEvent({ name: "filter_apply", filter: "price_max", value: "20" }), null);
});

test("durations, dwell and subtotals are bucketed; no exact amounts are stored", () => {
  assert.equal(bucket(5, DURATION_EDGES), "0-10");
  assert.equal(bucket(4000, DURATION_EDGES), "3600+");
  assert.equal(bucket(-1, DURATION_EDGES), undefined);
  assert.equal(cleanEvent({ name: "session_end", duration_s: 95 }).props.duration_s, "60-180");
  const c = cleanEvent({ name: "checkout_complete", brand: "koba-skincare", via: "buy_now", item_count: 2, subtotal: 63.5,
    email: "x@y.z", address: "1 Main St" });
  assert.deepEqual(c.props, { item_count: 2, subtotal: "50-100" });
  assert.equal(cleanEvent({ name: "checkout_start", via: "teleport" }), null);
});

test("PII never lands in the table: emails, long numbers, names and addresses are dropped", async (t) => {
  const { db, post } = await server(t);
  const app = { "User-Agent": APP, "X-Marracat-Device": DEVICE };
  await post({ events: [
    { name: "search", q: "jane@example.com" },
    { name: "search", q: "4111 1111 1111 1111" },
    { name: "checkout_start", via: "review", subtotal: 80, name_on_card: "Jane Doe", address: "1 Main St", email: "jane@example.com" },
    { name: "sign_up_complete", provider: "email", email: "jane@example.com" },
  ] }, app);
  const all = JSON.stringify(db.prepare("SELECT * FROM site_events").all());
  for (const bad of ["jane@example.com", "4111", "Jane Doe", "1 Main St", DEVICE]) assert.ok(!all.includes(bad), bad);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM site_events").get().n, 2, "the two searches were refused");
});

test("signed-in shoppers are a salted hash from the session, never the id or a client claim", async (t) => {
  const db = new Database(":memory:");
  const app = express();
  app.set("trust proxy", "loopback");
  eventRoutes(app, db, { env: { OWNER_EMAILS: "owner@example.test", AUTH_SECRET: "s3cret" },
    appViewer: (req) => (req.get("X-Test-App-User") ? { id: "google:123", email: req.get("X-Test-App-User") } : null) });
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => { s.close(); db.close(); });
  const post = (body, headers) => fetch(`http://127.0.0.1:${s.address().port}/api/events`, { method: "POST",
    headers: { "Content-Type": "application/json", "User-Agent": APP, "X-Marracat-Device": DEVICE, ...headers }, body: JSON.stringify(body) });
  await post({ name: "app_open", signed_in: true, user: "google:999" }, {});
  await post({ name: "app_open" }, { "X-Test-App-User": "shopper@example.test" });
  const rows = db.prepare("SELECT signed_in, user_hash FROM site_events ORDER BY id").all();
  assert.deepEqual(rows[0], { signed_in: 0, user_hash: null }, "a client can't claim to be signed in");
  assert.equal(rows[1].signed_in, 1);
  assert.equal(rows[1].user_hash, userHash("google:123", "s3cret"));
  assert.ok(!JSON.stringify(rows).includes("google:123"));
});

test("the report: funnel by platform, screens, engagement, sign-in, notifications, people", () => {
  const db = new Database(":memory:");
  eventRoutes(express(), db);
  const now = Date.now();
  const ios = (v, body, meta = {}) => recordEvent(db, v.repeat(20), cleanEvent(body, "ios"), now, meta);
  ios("a", { name: "app_open" }); ios("a", { name: "product_view", product: "p-1" }); ios("a", { name: "add_to_cart", product: "p-1" });
  ios("a", { name: "checkout_start", via: "buy_now" }); ios("a", { name: "checkout_complete", via: "buy_now" });
  ios("b", { name: "app_open" }, { signedIn: true, userHash: "h1" }); ios("b", { name: "screen_view", screen: "home" }, { signedIn: true, userHash: "h1" });
  ios("b", { name: "alert_on", kind: "restock" }); ios("b", { name: "sign_in_start", provider: "apple" }); ios("b", { name: "sign_in_complete", provider: "apple" });
  ios("b", { name: "notification_open", kind: "shipped" });
  recordEvent(db, "a".repeat(20), cleanEvent({ name: "app_open" }, "ios"), now - 3 * 86_400_000);
  recordEvent(db, "w".repeat(20), cleanEvent({ e: "product_open", product: "p-2" }), now);
  const r = eventReport(db, { days: 7, now });
  assert.deepEqual(r.funnel_by_platform.ios, { opened: 2, viewed_a_product: 1, added_to_cart: 1, started_checkout: 1, completed_checkout: 1 });
  assert.equal(r.funnel_by_platform.web.viewed_a_product, 1);
  assert.deepEqual(r.top_screens[0], { screen: "home", platform: "ios", views: 1, people: 1 });
  assert.equal(r.engagement.alert_on.events, 1);
  assert.deepEqual(r.alerts_by_kind[0], { kind: "restock", turned_on: 1, turned_off: 0 });
  assert.deepEqual(r.sign_in[0], { provider: "apple", started: 1, signed_in: 1, signed_up: 0 });
  assert.equal(r.notification_opens[0].kind, "shipped");
  assert.equal(r.people.ios.dau_today, 2);
  assert.equal(r.people.ios.came_back_on_2plus_days, 1, "a came back on another day");
  assert.equal(r.people.ios.signed_in_people, 1);
  assert.equal(r.people.ios.accounts, 1);
  assert.equal(r.people.web.wau, 1);
});

test("website pages map to the app's screen names; pages the app lacks send none", () => {
  const p = (q) => new URLSearchParams(q);
  assert.equal(screenFor("/", p("")), "home");
  assert.equal(screenFor("/shop", p("q=candle")), "search");
  assert.equal(screenFor("/shop", p("brand=koba")), "brand");
  assert.equal(screenFor("/shop", p("brand=koba&sale=1")), "browse");
  assert.equal(screenFor("/shop", p("category=beauty&aisle=hair")), "aisle");
  assert.equal(screenFor("/true-metal", p("")), "browse");
  assert.equal(screenFor("/checkout", p("")), "checkout_review");
  assert.equal(screenFor("/privacy", p("")), null);
  for (const path of ["/", "/shop", "/product", "/cart", "/checkout", "/account", "/saved", "/boosts", "/brands"]) {
    const screen = screenFor(path, p(""));
    assert.ok(cleanEvent({ e: "screen_view", screen }), `${path} → ${screen} passes the schema`);
  }
});

test("website checkout props: item count, one-currency subtotal (bucketed by the server), none when mixed", () => {
  const line = (price, quantity, currency = "USD") => ({ quantity, variant: { price }, product: { currency } });
  assert.deepEqual(checkoutProps([line(20, 2), line(15, 1)], "review", "koba"), { via: "review", brand: "koba", item_count: 3, subtotal: 55 });
  assert.equal(checkoutProps([line(20, 1), line(15, 1, "GBP")], "review").subtotal, undefined);
  const ev = cleanEvent({ e: "checkout_start", ...checkoutProps([line(20, 2), line(15, 1)], "review", "koba") });
  assert.equal(ev.props.subtotal, "50-100", "the exact amount never reaches the table");
});

test("every event the website sends is in the catalog", () => {
  const dir = new URL("../src/", import.meta.url);
  const files = readdirSync(dir, { recursive: true }).filter((f) => /\.(jsx?|mjs)$/.test(f));
  const sent = new Set();
  for (const f of files)
    for (const m of readFileSync(new URL(f, dir), "utf8").matchAll(/track\(\s*(?:[^,]*\?\s*)?"([a-z_]+)"(?:\s*:\s*"([a-z_]+)")?/g))
      for (const n of [m[1], m[2]]) if (n) sent.add(n);
  for (const n of ["screen_view", "save", "unsave", "share", "sign_in_start", "sign_in_complete", "checkout_start",
    "checkout_complete", "alert_on", "alert_off", "brand_follow", "brand_unfollow", "remove_from_cart", "comment_post"])
    assert.ok(sent.has(n), `the website sends ${n}`);
  for (const n of sent) assert.ok(EVENT_NAMES.includes(n), `${n} is sent by the website but has no schema`);
});

test("events-report.js prints every section from a real database file", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "events-report-"));
  try {
    const db = new Database(path.join(dir, "marracat.sqlite"));
    eventRoutes(express(), db);
    const now = Date.now();
    const ios = (body, meta = {}) => recordEvent(db, "i".repeat(20), cleanEvent(body, "ios"), now, meta);
    ios({ name: "app_open" }); ios({ name: "screen_view", screen: "home" }); ios({ name: "save", product: "p-1" });
    ios({ name: "alert_on", kind: "price", product: "p-1" }); ios({ name: "sign_in_start", provider: "apple" });
    ios({ name: "notification_open", kind: "shipped" }); ios({ name: "checkout_start", via: "buy_now" });
    ios({ name: "rec_view", row: "taste" });
    db.close();
    const script = new URL("../server/events-report.js", import.meta.url).pathname;
    const out = execFileSync(process.execPath, [script, "--days", "7"], { env: { ...process.env, DATA_DIR: dir }, encoding: "utf8" });
    for (const s of ["Funnel, ios (people): opened 1", "People, ios:", "WAU 1", "Top screens:", "save: 1", "Alerts by kind:",
      "Sign-in funnel:", "Notification opens:", "Checkouts:", "Recommendation rows, last 7 days:", "Website funnel (visitors)"])
      assert.ok(out.includes(s), `report shows "${s}"\n${out}`);
    const json = JSON.parse(execFileSync(process.execPath, [script, "--json"], { env: { ...process.env, DATA_DIR: dir }, encoding: "utf8" }));
    assert.equal(json.people.ios.wau, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// 2026-11-04: six of seven App Store users had screen views but no visit row
// (VisitPing fires only on a return to the foreground).
test("the app's events make it that day's visitor; the website's don't", async (t) => {
  const { db, post } = await server(t);
  const app = { "User-Agent": "Marracat/173 channel/appstore iOS/26.6", "X-Marracat-Device": DEVICE };
  assert.equal((await post({ name: "app_open" }, app)).status, 204);
  assert.equal((await post({ name: "rec_view", row: "taste" }, app)).status, 204);
  const rows = db.prepare("SELECT visitor, platform, build, channel FROM visits").all();
  assert.equal(rows.length, 1, "one row a day");
  assert.deepEqual({ ...rows[0], visitor: undefined }, { visitor: undefined, platform: "ios", build: "173", channel: "appstore" });
  assert.equal(rows[0].visitor, db.prepare("SELECT visitor FROM site_events LIMIT 1").get().visitor, "the same hashed id as its events");
  assert.equal((await post({ id: "webvisitor0000000001", name: "rec_view", row: "complements" })).status, 204);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM visits").get().n, 1, "the website's ping credits its referrer, so events leave visits alone");
});

// 2026-11-09: 45 of 74 iPhone visitor-days in two weeks were a lone Home view
// from a background launch (catalog refresh), with no app_open.
test("a background launch's screen views aren't stored and don't make a visit; a session's are", async (t) => {
  const { db, post, count } = await server(t);
  const app = { "User-Agent": "Marracat/173 channel/appstore iOS/26.6", "X-Marracat-Device": DEVICE };
  const background = { events: [{ name: "screen_view", screen: "home" }, { name: "rec_view", row: "taste" }] };
  assert.equal((await post(background, app)).status, 204);
  assert.equal(count(), 0, "a lone Home view is dropped");
  assert.equal(db.prepare("SELECT COUNT(*) n FROM visits").get().n, 0, "and isn't a visit");
  // A cold launch sends app_open with its first views.
  assert.equal((await post({ events: [{ name: "app_open" }, ...background.events] }, app)).status, 204);
  assert.equal((await post({ name: "screen_view", screen: "product" }, app)).status, 204, "later batches of the session count");
  assert.equal(count(), 4);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM visits").get().n, 1);
  // Closed, then launched in the background again.
  assert.equal((await post({ name: "session_end", duration_s: 90 }, app)).status, 204);
  assert.equal((await post(background, app)).status, 204);
  assert.equal(count(), 5, "views after session_end are dropped");
  // A tap is never a background launch.
  assert.equal((await post({ events: [{ name: "screen_view", screen: "home" }, { name: "search", q: "soap" }] }, app)).status, 204);
  assert.deepEqual(db.prepare("SELECT name FROM site_events ORDER BY id DESC LIMIT 1").all().map((r) => r.name), ["search"]);
  // The website has no background launches.
  assert.equal((await post({ id: ID, e: "product_open", product: "koba-1" })).status, 204);
  assert.equal(count(), 7);
});

test("an app session left open more than six hours (killed in the foreground) is over", () => {
  const db = new Database(":memory:");
  eventRoutes(express(), db);
  const now = Date.now(), view = [cleanEvent({ name: "screen_view", screen: "home" }, "ios")];
  recordEvent(db, DEVICE, cleanEvent({ name: "app_open" }, "ios"), now - SESSION_GAP_MS - 60_000);
  assert.equal(inAppSession(db, DEVICE, view, now), false);
  recordEvent(db, DEVICE, cleanEvent({ name: "app_open" }, "ios"), now - 60_000);
  assert.equal(inAppSession(db, DEVICE, view, now), true);
  assert.equal(inAppSession(db, "z".repeat(64), view, now), false, "another device's session doesn't count");
});
