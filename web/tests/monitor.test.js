// The Monitor page's data (server/monitor.js, owner 2026-11-15): what is kept,
// what is cleaned out, and what the dashboard reads back.
import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { batcher, catchUpRollups, cleanClient, cleanText, installMonitorSchema, journey, monitorMiddleware, monitorRoutes,
  overview, platformOf, pruneMonitor, routeOf, stream } from "../server/monitor.js";

const BROWSER = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
const APP = "Marracat/188 CFNetwork/1.0 Darwin/25.0 channel/testflight";
const KEY = "k".repeat(40);
const VISITOR = "visitor-0123456789abcdef";

test("text shown on the page loses emails, long numbers and query strings", () => {
  assert.equal(cleanText("Signed in as kim@example.com"), "Signed in as …@…");
  assert.equal(cleanText("Order 4111 1111 1111 1111 failed"), "Order … failed");
  assert.equal(cleanText("GET https://marracat.com/api/x?token=abc failed"), "GET https://marracat.com/api/x failed");
  assert.equal(cleanText("  a\n\n b  "), "a b");
  assert.equal(cleanText(""), null);
  assert.equal(cleanText("x".repeat(300), 10).length, 10);
});

test("paths become route patterns", () => {
  assert.equal(routeOf("/api/products/gently-soap-5832925544600?x=1"), "/api/products/:id");
  assert.equal(routeOf("/api/alerts/prefs"), "/api/alerts/prefs");
  assert.equal(routeOf("https://marracat.com/api/orders/0f8fad5b-d9cb-469f-a165-70867728950e"), "/api/orders/:id");
  assert.equal(routeOf("/cart/123:1,456:2"), "/cart/:id");
  assert.equal(routeOf("not a path"), null);
  assert.equal(platformOf(APP), "ios");
  assert.equal(platformOf(BROWSER), "web");
  assert.equal(platformOf("Googlebot/2.1"), "bot");
});

test("client rows keep only what each kind needs", () => {
  assert.deepEqual(cleanClient({ k: "tap", n: "  Add to  bag ", sc: "product" }), { kind: "tap", name: "Add to bag", screen: "product",
    method: null, status: null, ms: null, message: null, offset: 0 });
  assert.equal(cleanClient({ k: "tap" }), null, "a tap needs a label");
  assert.equal(cleanClient({ k: "keystroke", n: "a" }), null, "unknown kinds are refused");
  const api = cleanClient({ k: "api", n: "/api/query?q=soap", m: "post", st: 503, ms: 812, msg: "POST /api/query answered 503" });
  assert.deepEqual([api.name, api.method, api.status, api.ms, api.message], ["/api/query", "POST", 503, 812, "POST /api/query answered 503"]);
  assert.equal(cleanClient({ k: "api", n: "/api/x", st: 200, ms: 5, msg: "fine" }).message, null, "only failures keep a message");
  assert.equal(cleanClient({ k: "api", n: "/api/x", st: 9999, ms: -1 }).status, null);
  assert.equal(cleanClient({ k: "error", n: "js", msg: "x is not defined (main.js:1)" }).message, "x is not defined (main.js:1)");
  assert.equal(cleanClient({ k: "error", n: "js" }), null, "an error needs its message");
  assert.equal(cleanClient({ k: "screen", sc: "Product" }).name, "product");
});

function seed(db, now) {
  installMonitorSchema(db);
  const w = batcher(db, { everyMs: 1e9 });
  const at = (minAgo) => now - minAgo * 60e3;
  for (let i = 0; i < 18; i++) w.request({ ts: at(i), platform: "web", method: "GET", route: "/api/query", status: 200, ms: 10 + i, build: null, owner: false });
  w.request({ ts: at(3), platform: "web", method: "GET", route: "/api/query", status: 503, ms: 900, build: null, owner: false });
  w.request({ ts: at(2), platform: "ios", method: "POST", route: "/api/events", status: 204, ms: 4, build: "188", owner: false });
  w.request({ ts: at(2), platform: "bot", method: "GET", route: "/api/products/:id", status: 200, ms: 4, build: null, owner: false });
  w.request({ ts: at(1), platform: "web", method: "GET", route: "/api/secret-owner-route", status: 200, ms: 4, build: null, owner: true });
  const c = (minAgo, kind, extra) => w.client({ ts: at(minAgo), platform: "web", visitor: "aaaa1111bbbb2222", session: "s1", kind,
    name: null, screen: "product", method: null, status: null, ms: null, message: null, build: null, owner: false, ...extra });
  c(5, "screen", { name: "product" });
  c(4, "tap", { name: "Add to bag" });
  c(4, "tap", { name: "Add to bag", visitor: "cccc3333dddd4444" });
  c(3, "api", { name: "/api/query", method: "GET", status: 503, ms: 950 });
  c(2, "error", { name: "js", message: "x is not defined" });
  w.flush();
}

test("the overview counts requests by platform, routes, taps and errors, leaving bots and the owner out", () => {
  const db = new Database(":memory:"); const now = Date.UTC(2026, 10, 15, 20, 0);
  seed(db, now);
  const o = overview(db, { range: "1h" }, now);
  assert.equal(o.kpis.requests, 20, "18 + 1 failed web + 1 app; no bot, no owner");
  assert.equal(o.kpis.server_errors, 1);
  assert.equal(o.kpis.error_rate, 5);
  assert.equal(o.routes[0].route, "GET /api/query");
  assert.equal(o.routes[0].errors, 1);
  assert.ok(o.routes[0].p95 >= o.routes[0].p50);
  assert.ok(!o.routes.some((r) => r.route.includes("secret-owner-route")));
  assert.deepEqual(o.taps.map((t) => [t.name, t.n, t.visitors]), [["Add to bag", 2, 2]]);
  assert.equal(o.kpis.client_errors, 2, "the failed call and the script error");
  assert.ok(o.errors.some((e) => e.message === "x is not defined"));
  assert.ok(o.errors.some((e) => e.source === "server" && e.n === 1));
  assert.equal(o.series.reduce((n, s) => n + s.web.n + s.ios.n, 0), 20);
  // Filters: the app only; and the owner on request.
  assert.equal(overview(db, { range: "1h", platform: "ios" }, now).kpis.requests, 1);
  assert.equal(overview(db, { range: "1h", owner: "1" }, now).kpis.requests, 21);
  assert.equal(overview(db, { range: "1h", status: "5xx" }, now).kpis.requests, 1);
  assert.equal(overview(db, { range: "1h", q: "events" }, now).kpis.requests, 1);
});

test("the stream is newest first; a journey is one visitor's rows in order", () => {
  const db = new Database(":memory:"); const now = Date.UTC(2026, 10, 15, 20, 0);
  seed(db, now);
  const s = stream(db, { range: "1h" }, now);
  assert.ok(s.rows.length >= 20);
  assert.ok(s.rows.every((r, i, a) => i === 0 || a[i - 1].ts >= r.ts));
  assert.equal(stream(db, { range: "1h", kind: "tap" }, now).rows.length, 2);
  const j = journey(db, "aaaa1111", {}, now);
  assert.equal(j.sessions.length, 1);
  assert.deepEqual(j.sessions[0].rows.map((r) => r.kind), ["screen", "tap", "api", "error"]);
  assert.equal(journey(db, "not-hex").visitor, null);
});

test("hourly totals carry long ranges; raw rows go after 30 days", () => {
  const db = new Database(":memory:"); const now = Date.UTC(2026, 10, 15, 20, 30);
  seed(db, Date.UTC(2026, 10, 15, 18, 40));
  assert.ok(catchUpRollups(db, now) >= 2);
  const o = overview(db, { range: "7d" }, now);
  assert.equal(o.source, "hourly");
  assert.equal(o.kpis.requests, 20);
  assert.ok(o.taps.some((t) => t.name === "Add to bag" && t.n === 2));
  pruneMonitor(db, now + 31 * 86400e3);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM requests").get().n, 0);
  assert.ok(db.prepare("SELECT COUNT(*) n FROM hourly").get().n > 0, "hourly totals stay a year");
});

async function app(t) {
  const main = new Database(":memory:"), mdb = new Database(":memory:");
  installMonitorSchema(mdb);
  const w = batcher(mdb, { everyMs: 1e9 });
  const a = express();
  a.set("trust proxy", "loopback");
  a.use(monitorMiddleware(w));
  a.get("/api/thing/:id", (req, res) => res.json({ ok: true }));
  a.get("/api/health", (req, res) => res.json({ ok: true }));
  monitorRoutes(a, main, mdb, w, { env: { METRICS_KEY: KEY, OWNER_EMAILS: "owner@example.test" },
    viewer: async (req) => (req.get("X-Test-User") ? { id: "u", email: req.get("X-Test-User") } : null) });
  const s = a.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => { w.stop(); s.close(); main.close(); mdb.close(); });
  const base = `http://127.0.0.1:${s.address().port}`;
  return { mdb, w, base };
}

test("the request log times each route by its pattern", async (t) => {
  const { mdb, w, base } = await app(t);
  await fetch(`${base}/api/thing/abc?secret=1`, { headers: { "User-Agent": BROWSER } });
  await fetch(`${base}/api/thing/xyz`, { headers: { "User-Agent": APP } });
  await fetch(`${base}/api/health`, { headers: { "User-Agent": BROWSER } });   // uptime checks aren't counted
  await new Promise((r) => setTimeout(r, 20));
  w.flush();
  const rows = mdb.prepare("SELECT platform, route, status, build FROM requests ORDER BY rowid").all();
  assert.deepEqual(rows.map((r) => [r.platform, r.route, r.status, r.build]), [["web", "/api/thing/:id", 200, null], ["ios", "/api/thing/:id", 200, "188"]]);
});

test("POST /api/monitor stores hashed visitors, flags the owner, and the dashboard key guards the read", async (t) => {
  const { mdb, w, base } = await app(t);
  const post = (body, headers = {}) => fetch(`${base}/api/monitor`, { method: "POST",
    headers: { "Content-Type": "application/json", "User-Agent": BROWSER, ...headers }, body: JSON.stringify(body) });
  const now = Date.now();
  assert.equal((await post({ id: VISITOR, s: "sess123456", now, ev: [{ k: "tap", n: "Check out", sc: "cart", t: now - 1000 }, { k: "bogus" }] })).status, 204);
  assert.equal((await post({ id: VISITOR, now, ev: [{ k: "tap", n: "Mine" }] }, { "X-Test-User": "owner@example.test" })).status, 204);
  assert.equal((await post({ id: "short", ev: [{ k: "tap", n: "x" }] })).status, 400, "a visitor id is required");
  assert.equal((await post({ id: VISITOR, ev: [] })).status, 400);
  assert.equal((await post({ id: VISITOR, ev: [{ k: "tap", n: "x" }] }, { "User-Agent": "Googlebot/2.1" })).status, 204);
  w.flush();
  const rows = mdb.prepare("SELECT visitor, session, kind, name, screen, owner, ts FROM client ORDER BY rowid").all();
  assert.equal(rows.length, 2, "the bogus kind and the bot are dropped");
  assert.equal(rows[0].visitor.length, 16);
  assert.notEqual(rows[0].visitor, VISITOR, "never the raw id");
  assert.deepEqual([rows[0].kind, rows[0].name, rows[0].screen, rows[0].owner], ["tap", "Check out", "cart", 0]);
  assert.ok(Math.abs(now - 1000 - rows[0].ts) < 2000, "the tap's own time, from the client's clock offset");
  assert.equal(rows[1].owner, 1, "the owner is kept but flagged");
  assert.equal((await fetch(`${base}/api/owner/monitor`)).status, 404, "no key, no route");
  const r = await fetch(`${base}/api/owner/monitor?range=1h&view=stream&kind=tap`, { headers: { "X-Metrics-Key": KEY } });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.deepEqual(body.rows.map((x) => x.name), ["Check out"], "the owner's tap is hidden by default");
});

test("the app's screens and actions, and the website's from before monitoring, come from the events log", async () => {
  const { installEventSchema, recordEvent } = await import("../server/events.js");
  const db = new Database(":memory:"), main = new Database(":memory:");
  const now = Date.UTC(2026, 10, 15, 20, 0);
  seed(db, now);
  installEventSchema(main);
  const ev = (minAgo, name, props, platform = "ios") => recordEvent(main, "app-device-0123456789", { name, platform, props, row: null },
    now - minAgo * 60e3, { build: "188" });
  ev(9, "screen_view", { screen: "home" });
  ev(8, "add_to_cart", {});
  ev(8, "rec_view", {});
  ev(8, "banner_view", {});
  ev(7, "add_to_cart", {}, "web");   // before the website's monitor began (its first row is 5 min ago)
  ev(1, "add_to_cart", {}, "web");   // after: the monitor has it, so the log's copy isn't counted again
  const o = overview(db, { range: "1h" }, now, main);
  assert.ok(o.taps.some((t) => t.name === "Add to cart" && t.n === 2 && t.ios === 1 && t.web === 1), JSON.stringify(o.taps));
  assert.ok(o.screens.some((s) => s.screen === "home"));
  assert.ok(!o.taps.some((t) => /^(Rec|Banner) view/.test(t.name)), "views without a tap are left out");
  assert.ok(o.builds.includes("188"));
  assert.equal(overview(db, { range: "1h", platform: "web" }, now, main).taps.find((t) => t.name === "Add to cart").n, 1, "web before the monitor only");
  assert.equal(overview(db, { range: "1h", platform: "ios" }, now, main).taps.find((t) => t.name === "Add to cart").n, 1);
  const s = stream(db, { range: "1h", kind: "tap" }, now, 200, main);
  const code = s.rows.find((r) => r.src === "app").visitor;
  assert.equal(code.length, 8);
  const j = journey(db, code, {}, now, main);
  assert.deepEqual(j.sessions[0].rows.map((r) => [r.kind, r.platform]), [["screen", "ios"], ["tap", "ios"], ["tap", "web"]], "same device id in the test, both platforms");
});
