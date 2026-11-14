import express from "express";
import { createHash } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { brandRecord } from "./catalog.js";
import { apnsSender } from "./restock.js";
import { findTracking, carrierFor } from "./relay-parse.js";
import { trackerFor, trackerBudget, statusFrom17Track, detailFrom17Track, detailFromEasyPost, stepForTrackerStatus, dayOf, deleteRelayData, guestOwner } from "./relay.js";
import { claimPush, releasePush } from "./push-once.js";
import { liveCovers } from "./live-cover.js";
import { readText } from "./store-fetch.js";

// Order tracking that survives Apple Pay (owner, 2026-10-01: "we need to let
// people pay by apple pay and we need to be able to track it").
//
// Apple Pay and Shop Pay replace the checkout's email with the wallet's, so
// the relay address (relay.js) never sees those orders. What we do hold is the
// UCP checkout the app created (Checkout/UCP.swift). Once it's paid,
// `get_checkout` answers with `order { id, permalink_url }`: the brand's own
// order status page, the one its emails link to. This job reads that page on a
// schedule for the fulfillment state and the carrier's tracking number, and
// pushes each step to the phone.
//
// Same device-key scheme as restock alerts (X-Marracat-Device, stored hashed),
// so no account is needed; the push token is the one restock_devices holds.
//
// What isn't known until a real paid order runs through it (2026-10-01):
// whether the anonymous UCP tier returns `order` on a completed checkout, and
// whether the status page reads server-side or is a JS shell / sign-in wall.
// Every attempt logs a one-line diagnosis (never the page or any token), and
// the app always offers "Track package", which opens the page itself.
//
// A tracking number read off the page goes to 17TRACK too (owner, 2026-10-07),
// so the steps after "shipped" come from the carrier, not just the page; its
// pushes move the order forward the same way (track17Update below).

const hash = (value) => createHash("sha256").update(value).digest("hex");
const deviceKey = /^[a-f0-9]{64}$/;
const checkoutID = /^gid:\/\/shopify\/Checkout\/[A-Za-z0-9_-]{8,80}(\?key=[a-f0-9]{16,64})?$/;
const orderGID = /^gid:\/\/shopify\/(?:Order|OrderIdentity)\/\d{1,20}$/;

export const TRACK_EVERY_MS = 10 * 60_000;     // the job wakes every 10 minutes
const PAGE_EVERY_MS = 10 * 60_000;             // each status page every 10 minutes (owner, 2026-10-09; was 45)
const RESOLVE_FOR_MS = 2 * 60 * 60_000;        // keep asking get_checkout for 2 hours
const GIVE_UP_MS = 30 * 24 * 60 * 60_000;      // stop tracking after 30 days
const PER_RUN = 60;
const MAX_OPEN = 50;
const FETCH_TIMEOUT_MS = 12_000;
const MAX_PAGE = 2_000_000;

export const STEPS = ["confirmed", "shipped", "out_for_delivery", "delivered"];

export function installTrackingSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS tracked_orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device TEXT NOT NULL, brand_id TEXT NOT NULL,
      checkout_id TEXT NOT NULL, order_gid TEXT,
      permalink TEXT, state TEXT, carrier TEXT, tracking_number TEXT, tracking_url TEXT,
      created INTEGER NOT NULL, resolved INTEGER, checked INTEGER, updated INTEGER, done INTEGER,
      diagnosis TEXT,
      UNIQUE(device, checkout_id));
    CREATE INDEX IF NOT EXISTS tracked_orders_open ON tracked_orders(done, checked);
  `);
  // item_title/item_count: what was bought, for "KOBA shipped your Keep It
  // Together Headband" (owner, 2026-10-08).
  // est_delivery: the carrier's expected day, for the Live Activity's
  // "arriving today" (live-activity.js, owner 2026-10-13).
  // relay_owner/relay_order: the order email this order is linked to
  // (relay-sync.js), as the relay's owner and "domain|order number".
  for (const col of ["tracker_id TEXT", "tracking_status TEXT", "item_title TEXT", "item_count INTEGER", "est_delivery TEXT", "relay_owner TEXT", "relay_order TEXT", "tracking_detail TEXT"])
    if (!db.prepare("SELECT 1 FROM pragma_table_info('tracked_orders') WHERE name=?").get(col.split(" ")[0]))
      db.exec(`ALTER TABLE tracked_orders ADD COLUMN ${col}`);
  db.exec("CREATE INDEX IF NOT EXISTS tracked_orders_tracker ON tracked_orders(tracker_id)");
}

// The brand's UCP endpoint, from our own catalog only: the phone names a
// brand, never a URL.
export function ucpEndpointFor(brandID, lookup = brandRecord) {
  const brand = lookup(brandID);
  if (!brand?.ucp) return null;
  try {
    const url = new URL(brand.ucp);
    if (url.protocol !== "https:" || !/\.myshopify\.com$/i.test(url.hostname) && !sameSite(url.hostname, brand.domain)) return null;
    return url;
  } catch { return null; }
}

const strip = (h) => String(h || "").toLowerCase().replace(/^www\./, "");
const sameSite = (host, domain) => {
  const h = strip(host), d = strip(domain);
  return !!d && (h === d || h.endsWith("." + d));
};

// A status page link we're willing to fetch: https, on the brand's own domain,
// a myshopify.com store or shopify.com, default port, no credentials. Applied
// to the link and to every redirect, so nothing leads the server elsewhere.
export function allowedPage(raw, brand) {
  let url;
  try { url = new URL(raw); } catch { return null; }
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443")) return null;
  const host = url.hostname.toLowerCase();
  const ok = sameSite(host, brand?.domain) || /\.myshopify\.com$/.test(host) || host === "shopify.com" || host.endsWith(".shopify.com");
  return ok ? url : null;
}

// ---- reading the status page --------------------------------------------

const CARRIERS = ["usps.com", "ups.com", "fedex.com", "dhl.com", "ontrac.com"];
/// The first https link whose host is a carrier's own domain. Until
/// 2026-11-12 any link that merely contained a carrier's name matched
/// (https://evil.example/?to=ups.com).
export function carrierLink(body) {
  for (const m of String(body).matchAll(/https:\/\/[^"'\s<>]+/gi)) {
    if (!/usps|ups|fedex|dhl|ontrac/i.test(m[0])) continue;
    let url;
    try { url = new URL(m[0]); } catch { continue; }
    const host = url.hostname.toLowerCase();
    if (!url.username && !url.password && !url.port && CARRIERS.some((c) => host === c || host.endsWith("." + c))) return m[0];
  }
  return null;
}

const decode = (s) => s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, "'").replace(/&nbsp;/g, " ");

// Where an order is, from Shopify's order status page. Works on the
// server-rendered page (its timeline reads "Confirmed", "On its way", "Out for
// delivery", "Delivered") and on JSON state embedded in it
// (displayFulfillmentStatus / shipmentStatus enums). Returns null for a page
// that says nothing about the order: a JS shell or a sign-in wall.
export function parseStatusPage(html = "") {
  const body = decode(html.slice(0, MAX_PAGE));
  const text = body.replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
  const enums = body.match(/"(?:displayFulfillmentStatus|shipmentStatus|status|deliveryStatus|latestShipmentStatus)"\s*:\s*"([A-Z_]{4,40})"/g) || [];
  const enumSet = new Set(enums.map((m) => m.match(/"([A-Z_]{4,40})"$/)[1]));
  // The page lists every step ("Confirmed · On its way · Out for delivery ·
  // Delivered"), so a bare label proves nothing: read the sentence about the
  // current step, or the step the page marks current.
  const current = (body.match(/class="[^"]*\b(?:current|active|is-current)\b[^"]*"[^>]*>\s*(?:<[^>]+>\s*)*(Confirmed|On its way|Out for delivery|Delivered)\b/i) || [])[1]?.toLowerCase();
  let state = null;
  if (/\b(?:was|has been) delivered\b|\bDelivered on\b/i.test(text) || enumSet.has("DELIVERED") || current === "delivered") state = "delivered";
  else if (/\b(?:is|are) out for delivery\b/i.test(text) || enumSet.has("OUT_FOR_DELIVERY") || current === "out for delivery") state = "out_for_delivery";
  else if (/\b(?:is on its way|are on (?:their|the) way|has shipped|shipped on|in transit)\b/i.test(text) || current === "on its way" ||
           ["IN_TRANSIT", "FULFILLED", "CONFIRMED_BY_CARRIER", "LABEL_PRINTED", "ATTEMPTED_DELIVERY"].some((e) => enumSet.has(e))) state = "shipped";
  else if (/\b(?:order (?:is )?confirmed|your order is confirmed|confirmed\b.*\border)\b/i.test(text) || enumSet.has("UNFULFILLED")) state = "confirmed";
  const tracking = findTracking(body, text);
  const trackingURL = carrierLink(body);
  if (tracking && !state) state = "shipped";
  const orderName = (text.match(/\bOrder\s+#\s?([A-Z0-9-]{3,20})\b/) || [])[1] || null;
  if (!state && !tracking) return null;
  return { state, carrier: tracking?.carrier || null, trackingNumber: tracking?.trackingNumber || null, trackingURL, orderName: orderName ? `#${orderName}` : null };
}

// One line about a fetch, for the log and the row: enough to tell a readable
// page from a shell or a wall on the first real order, with no token, address
// or page content in it.
export function diagnose({ status, finalURL, type, bytes, parsed, html = "" }) {
  const path = (() => { try { return new URL(finalURL).pathname.replace(/[a-f0-9]{16,}/gi, "…").slice(0, 60); } catch { return "?"; } })();
  const host = (() => { try { return new URL(finalURL).hostname; } catch { return "?"; } })();
  // "/authenticate?key=" is the normal status link, not a wall.
  const wall = /\/login|\/authentication\//i.test(path) || /verification code|log in to view|sign in to view|confirm your (?:order number|email)/i.test(html);
  const scripts = (html.match(/<script/gi) || []).length;
  const shell = !parsed && !wall && scripts > 0 && html.replace(/<script[\s\S]*?<\/script>/gi, "").replace(/<[^>]+>/g, "").trim().length < 400;
  const kind = parsed ? `read:${parsed.state || "?"}${parsed.trackingNumber ? "+tracking" : ""}` : wall ? "wall" : shell ? "js-shell" : "unrecognised";
  return `${status} ${host}${path} ${type || "?"} ${bytes}B ${kind}`;
}

async function fetchPage(start, brand, fetcher) {
  let url = start;
  for (let hop = 0; hop < 4; hop++) {
    const res = await fetcher(url, {
      redirect: "manual", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      headers: { "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                 Accept: "text/html,application/xhtml+xml" },
    });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      const next = allowedPage(new URL(res.headers.get("location"), url).toString(), brand);
      if (!next) return { status: res.status, finalURL: url.toString(), type: "redirect-refused", html: "" };
      url = next;
      continue;
    }
    const type = (res.headers.get("content-type") || "").split(";")[0];
    const text = type.includes("html") || type.includes("json") ? await readText(res, MAX_PAGE, { truncate: true }) : "";
    return { status: res.status, finalURL: url.toString(), type, html: text };
  }
  return { status: 0, finalURL: url.toString(), type: "too-many-redirects", html: "" };
}

// ---- asking the store for the order -------------------------------------

export async function getCheckout(endpoint, id, fetcher = fetch) {
  const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_checkout",
    arguments: { id, meta: { "ucp-agent": { profile: "https://marracat.com/.well-known/ucp" } } } } });
  const res = await fetcher(endpoint, { method: "POST", body, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "User-Agent": "Marracat/1.0 (+https://marracat.com)" } });
  if (!res.ok) return { error: `HTTP ${res.status}` };
  let raw = await readText(res, MAX_PAGE);
  if (raw == null) return { error: "too large" };
  if (/^(?:event|data):/m.test(raw)) raw = raw.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).pop() || "";
  let top;
  try { top = JSON.parse(raw); } catch { return { error: "unparseable" }; }
  if (top.error) return { error: `rpc ${top.error.code}` };
  const c = top.result?.structuredContent;
  if (!c?.id) return { error: "no checkout" };
  return { status: c.status, order: c.order || null };
}

// The carrier's own public tracking page for a number, for "Track package"
// on an order with no brand status page.
export function carrierTrackingURL(carrier, number) {
  const n = encodeURIComponent(number);
  return {
    UPS: `https://www.ups.com/track?tracknum=${n}`,
    USPS: `https://tools.usps.com/go/TrackConfirmAction?tLabels=${n}`,
    FedEx: `https://www.fedex.com/fedextrack/?trknbr=${n}`,
    DHLExpress: `https://www.dhl.com/us-en/home/tracking/tracking-express.html?tracking-id=${n}`,
    OnTrac: `https://www.ontrac.com/tracking/?number=${n}`,
  }[carrier] || `https://t.17track.net/en#nums=${n}`;
}

// ---- the job --------------------------------------------------------------

const stepIndex = (s) => STEPS.indexOf(s);

// "Keep It Together Headband", "Keep It Together Headband and 2 more items",
// or null when the app never said what was in the order.
export function itemPhrase(title, count) {
  const t = typeof title === "string" ? title.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 80) : "";
  if (!t) return null;
  const more = Number.isInteger(count) && count > 1 ? count - 1 : 0;
  return more ? `${t} and ${more} more item${more === 1 ? "" : "s"}` : t;
}

export const pushText = (state, brand, orderName, item = null) => {
  const order = orderName ? ` ${orderName}` : "";
  // With the item known, every step names it (owner, 2026-10-09).
  if (item) return {
    shipped: { title: "Shipped", body: `${brand} shipped your ${item}` },
    out_for_delivery: { title: "Out for delivery", body: `Your ${item} from ${brand} is out for delivery.` },
    delivered: { title: "Delivered", body: `Your ${item} from ${brand} was delivered.` },
    problem: { title: "Delivery problem", body: `The carrier reported a problem with your ${item} from ${brand}.` },
  }[state];
  return {
    shipped: { title: "Shipped", body: item ? `${brand} shipped your ${item}` : `${brand} shipped your order${order}.` },
    out_for_delivery: { title: "Out for delivery", body: `Your ${brand} order${order} is out for delivery.` },
    delivered: { title: "Delivered", body: `Your ${brand} order${order} was delivered.` },
    problem: { title: "Delivery problem", body: `The carrier reported a problem with your ${brand} order${order}.` },
  }[state];
};

async function pushStep(db, apns, row, state, brandName, orderName, log) {
  const text = pushText(state, brandName, orderName, itemPhrase(row.item_title, row.item_count));
  const device = db.prepare("SELECT token, environment FROM restock_devices WHERE hash=?").get(row.device);
  if (text && device?.token && apns?.configured?.()) {
    // Each step once per order on this phone (push-once.js). An order linked
    // to its order email (relay-sync.js) also claims the relay's key for the
    // step, so the email and the page/tracker never both announce it.
    const key = `${state}|${row.brand_id}|${row.order_gid ? row.order_gid.split("/").pop() : row.tracker_id || row.id}`;
    const relayKey = row.relay_owner && row.relay_order ? `${state}|${row.relay_order}` : null;
    if (relayKey && !claimPush(db, row.relay_owner, relayKey)) return;
    if (!claimPush(db, row.device, key)) { if (relayKey) releasePush(db, row.relay_owner, relayKey); return; }
    // The phone's delivery card announces this step itself (live-cover.js).
    if (liveCovers(db, row.device, state, Date.now(), { brand: brandName })) return;
    const result = await apns.send(device, { aps: { alert: text, sound: "default" }, trackedOrder: { orderID: row.order_gid, brandID: row.brand_id } });
    if (result.status !== 200) {
      releasePush(db, row.device, key);
      if (relayKey) releasePush(db, row.relay_owner, relayKey);
      log(`Order tracking push not delivered (${result.status} ${result.reason})`);
    }
  }
}

// The page's tracking number becomes a tracker once: reused when the relay or
// another order already follows that number, within the shared daily cap.
export async function startPageTracker(db, row, { tracker, budget, log = console.log } = {}) {
  if (!tracker || !row.tracking_number || row.tracker_id) return null;
  const relay = db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='relay_events'").get()
    ? " UNION ALL SELECT tracker_id FROM relay_events WHERE tracking_number=@n AND tracker_id IS NOT NULL" : "";
  const known = db.prepare(`SELECT tracker_id FROM tracked_orders WHERE tracking_number=@n AND tracker_id IS NOT NULL${relay} LIMIT 1`)
    .get({ n: row.tracking_number });
  if (known) { db.prepare("UPDATE tracked_orders SET tracker_id=? WHERE id=?").run(known.tracker_id, row.id); return known.tracker_id; }
  if (!budget.allowed()) { log(`${tracker.service} daily cap reached (${budget.cap}); order #${row.id} stays on its page`); return null; }
  try {
    const t = await tracker({ trackingNumber: row.tracking_number, carrier: row.carrier });
    const spent = budget.charge();
    db.prepare("UPDATE tracked_orders SET tracker_id=? WHERE id=?").run(t.id, row.id);
    log(`${t.service || tracker.service} tracker ${t.id} for order #${row.id} (${row.brand_id}); ${spent} today`);
    return t.id;
  } catch (e) { log(`${tracker.service} tracker for order #${row.id} failed: ${e.message}`); return null; }
}

// A 17TRACK push for a number an order page gave us: forward-only moves,
// a push for each new step and for a delivery problem, done once delivered.
export async function track17Update(db, payload, opts = {}) {
  const d = payload?.data;
  if (payload?.event !== "TRACKING_UPDATED" || typeof d?.number !== "string") return 0;
  const eta = d.track_info?.time_metrics?.estimated_delivery_date;
  return applyOrderTracking(db, d.number, statusFrom17Track(d.track_info?.latest_status), "17TRACK", { ...opts, est: dayOf(eta?.to) || dayOf(eta?.from), detail: detailFrom17Track(d.track_info) });
}

// The same for EasyPost's webhook (its USPS trackers, see trackerFor).
export async function easyPostUpdate(db, payload, opts = {}) {
  const t = payload?.result;
  if (payload?.description !== "tracker.updated" || typeof t?.id !== "string") return 0;
  return applyOrderTracking(db, t.id, t.status, "EasyPost", { ...opts, est: dayOf(t.est_delivery_date), detail: detailFromEasyPost(t) });
}

async function applyOrderTracking(db, trackerID, status, service, { apns, lookup = brandRecord, now = Date.now, log = console.log, est = null, detail = null } = {}) {
  const step = stepForTrackerStatus(status);
  const rows = db.prepare("SELECT * FROM tracked_orders WHERE tracker_id=? AND done IS NULL").all(trackerID);
  for (const row of rows) {
    if (est) db.prepare("UPDATE tracked_orders SET est_delivery=? WHERE id=?").run(est, row.id);
    if (detail) db.prepare("UPDATE tracked_orders SET tracking_detail=? WHERE id=?").run(detail, row.id);
    const name = brandNameFor(row.brand_id, lookup);
    const was = row.state || "confirmed";
    const next = step && step !== "problem" && stepIndex(step) > stepIndex(was) ? step : was;
    const problem = step === "problem" && row.tracking_status !== status;
    db.prepare("UPDATE tracked_orders SET tracking_status=?, state=?, updated=CASE WHEN ? THEN ? ELSE updated END, done=CASE WHEN ?='delivered' THEN ? ELSE NULL END WHERE id=?")
      .run(status, next, next !== was ? 1 : 0, now(), next, now(), row.id);
    if (next !== was) {
      log(`Order tracking #${row.id} (${row.brand_id}): ${was} -> ${next} [${service}]`);
      await pushStep(db, apns, row, next, name, null, log);
    } else if (problem) await pushStep(db, apns, row, "problem", name, null, log);
  }
  return rows.length;
}

const GONE = "brand no longer in the catalog; carrier tracking only";

/// The brand's name for a push; a brand no longer in the catalog is named
/// from its id ("the-butter-bar-skincare" -> "The Butter Bar Skincare").
export function brandNameFor(brandID, lookup = brandRecord) {
  const b = lookup(brandID);
  if (b?.name) return b.name;
  const words = String(brandID || "").split("-").filter(Boolean);
  return words.length ? words.map((w) => w[0].toUpperCase() + w.slice(1)).join(" ") : "Your";
}

export async function checkTrackedOrders(db, { apns, fetcher = fetch, lookup = brandRecord, now = Date.now, log = console.log, tracker = null, budget = null } = {}) {
  const t = now();
  const rows = db.prepare(`SELECT * FROM tracked_orders WHERE done IS NULL AND (checked IS NULL OR checked < ? OR (permalink IS NULL AND resolved IS NULL))
    ORDER BY COALESCE(checked, 0) LIMIT ?`).all(t - PAGE_EVERY_MS, PER_RUN);
  let resolved = 0, read = 0, moved = 0;
  for (const row of rows) {
    const brand = lookup(row.brand_id);
    if (t - row.created > GIVE_UP_MS) {
      db.prepare("UPDATE tracked_orders SET done=? WHERE id=?").run(t, row.id);
      continue;
    }
    // A brand taken out of the catalog after the order was placed (2026-10-13:
    // The Butter Bar's shipped order kept closing): the order still ships, so
    // it stays open on carrier tracking alone. No brand record means no status
    // page or UCP call; a tracking number already held, or added later, goes to
    // the tracker, whose updates (and delivery) move and close it.
    if (!brand) {
      if (!row.resolved || row.diagnosis !== GONE) db.prepare("UPDATE tracked_orders SET resolved=COALESCE(resolved, ?), state=COALESCE(state, 'confirmed'), diagnosis=? WHERE id=?")
        .run(t, GONE, row.id);
      db.prepare("UPDATE tracked_orders SET checked=? WHERE id=?").run(t, row.id);
      if (tracker && row.tracking_number && !row.tracker_id && row.state !== "delivered") await startPageTracker(db, row, { tracker, budget, log });
      continue;
    }
    let permalink = row.permalink;
    // No status page to read (owner, 2026-10-13: every in-app order gets a
    // row, whichever button paid): an order the app registered by its Shopify
    // order id alone (no UCP checkout), a brand with no UCP endpoint, or a
    // checkout get_checkout never resolved. The row stays open for its 30
    // days; a tracking number, added in the app or found later, goes to the
    // tracker, whose pushes move the order.
    if (!permalink && (!checkoutID.test(row.checkout_id) || t - row.created > RESOLVE_FOR_MS || !ucpEndpointFor(row.brand_id, lookup))) {
      if (!row.resolved) {
        const why = !checkoutID.test(row.checkout_id) ? "no UCP checkout, order id only" : !ucpEndpointFor(row.brand_id, lookup) ? "no UCP endpoint" : "get_checkout never returned an order";
        db.prepare("UPDATE tracked_orders SET resolved=?, state=COALESCE(state, 'confirmed'), diagnosis=? WHERE id=?").run(t, why, row.id);
        log(`Order tracking #${row.id} (${row.brand_id}): no status page (${why}); waiting for a tracking number`);
      }
      db.prepare("UPDATE tracked_orders SET checked=? WHERE id=?").run(t, row.id);
      if (tracker && row.tracking_number && !row.tracker_id && row.state !== "delivered") await startPageTracker(db, row, { tracker, budget, log });
      continue;
    }
    if (!permalink) {
      const endpoint = ucpEndpointFor(row.brand_id, lookup);
      let r;
      try { r = await getCheckout(endpoint.toString(), row.checkout_id, fetcher); } catch (e) { r = { error: e.name }; }
      const url = r.order?.permalink_url && allowedPage(r.order.permalink_url, brand);
      const note = r.error ? `get_checkout ${r.error}` : `get_checkout ${r.status}${r.order ? (url ? " +order" : " +order(refused link)") : " no order"}`;
      if (!url) {
        db.prepare("UPDATE tracked_orders SET diagnosis=? WHERE id=?").run(note, row.id);
        log(`Order tracking #${row.id} (${row.brand_id}): ${note}`);
        continue;
      }
      permalink = url.toString();
      db.prepare("UPDATE tracked_orders SET permalink=?, order_gid=COALESCE(order_gid, ?), resolved=?, state=COALESCE(state, 'confirmed'), diagnosis=? WHERE id=?")
        .run(permalink, orderGID.test(r.order.id || "") ? r.order.id : null, t, note, row.id);
      log(`Order tracking #${row.id} (${row.brand_id}): ${note}`);
      resolved++;
    }
    const start = allowedPage(permalink, brand);
    if (!start) { db.prepare("UPDATE tracked_orders SET done=?, diagnosis=? WHERE id=?").run(t, "status link refused", row.id); continue; }
    let page;
    try { page = await fetchPage(start, brand, fetcher); } catch (e) { page = { status: 0, finalURL: start.toString(), type: e.name, html: "" }; }
    const parsed = page.status === 200 ? parseStatusPage(page.html) : null;
    const diagnosis = diagnose({ status: page.status, finalURL: page.finalURL, type: page.type, bytes: page.html.length, parsed, html: page.html });
    read++;
    const was = row.state || "confirmed";
    const next = parsed?.state && stepIndex(parsed.state) > stepIndex(was) ? parsed.state : was;
    db.prepare(`UPDATE tracked_orders SET checked=?, diagnosis=?, state=?, carrier=COALESCE(?, carrier), tracking_number=COALESCE(?, tracking_number),
      tracking_url=COALESCE(?, tracking_url), updated=CASE WHEN ? THEN ? ELSE updated END, done=CASE WHEN ?='delivered' THEN ? ELSE NULL END WHERE id=?`)
      .run(t, diagnosis, next, parsed?.carrier || null, parsed?.trackingNumber || null, parsed?.trackingURL || null,
           next !== was ? 1 : 0, t, next, t, row.id);
    if (next !== was) {
      moved++;
      log(`Order tracking #${row.id} (${row.brand_id}): ${was} -> ${next} [${diagnosis}]`);
      await pushStep(db, apns, row, next, brand.name, parsed?.orderName, log);
    } else if (!parsed) {
      log(`Order tracking #${row.id} (${row.brand_id}): page not readable [${diagnosis}]`);
    }
    if (tracker && next !== "delivered") await startPageTracker(db, db.prepare("SELECT * FROM tracked_orders WHERE id=?").get(row.id), { tracker, budget, log });
  }
  return { orders: rows.length, resolved, read, moved };
}

// ---- routes ------------------------------------------------------------------

export function trackingRoutes(app, db, { env = process.env, apns = apnsSender(env), lookup = brandRecord, fetcher = fetch, schedule = env.NODE_ENV === "production",
  tracker = trackerFor(env), onRegister = () => {} } = {}) {
  installTrackingSchema(db);
  const budget = trackerBudget(db, env);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 60, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "4kb" }));
  router.use((req, res, next) => {
    const key = req.get("X-Marracat-Device");
    if (!key || !deviceKey.test(key)) return res.status(401).json({ error: "Missing device key" });
    req.device = hash(key);
    next();
  });
  const list = (device) => db.prepare(`SELECT brand_id AS brandID, checkout_id AS checkoutID, order_gid AS orderID, permalink, state,
      carrier, tracking_number AS trackingNumber, tracking_url AS trackingURL, created, updated,
      tracking_status AS trackingStatus, tracking_detail AS trackingDetail
      FROM tracked_orders WHERE device=? ORDER BY created DESC LIMIT 100`).all(device)
    // The checkout's key is a credential to that checkout: the phone that sent
    // it already has it, so it's matched on, never echoed back in full.
    .map((o) => ({ ...o, checkoutID: o.checkoutID.split("?")[0] }));

  // The app calls this when Checkout Kit reports any paid Shopify checkout
  // (owner, 2026-10-13). With the UCP checkout it built, the job follows the
  // brand's status page; without one (a brand with no UCP endpoint, a cart
  // link checkout) the Shopify order id keys the row and tracking comes from
  // a number added later.
  router.post("/", (req, res) => {
    const { brandID, checkoutID: sent, orderID, itemTitle, itemCount } = req.body || {};
    const brand = typeof brandID === "string" && brandID.length <= 120 ? lookup(brandID) : null;
    if (!brand || !(brand.shopify || brand.ucp)) return res.status(422).json({ error: "This brand can't be tracked" });
    if (sent != null && !(typeof sent === "string" && checkoutID.test(sent))) return res.status(400).json({ error: "Invalid checkout" });
    if (orderID != null && !(typeof orderID === "string" && orderGID.test(orderID))) return res.status(400).json({ error: "Invalid order" });
    if (sent == null && orderID == null) return res.status(400).json({ error: "Invalid checkout" });
    const id = sent ?? orderID;
    if (itemTitle != null && !(typeof itemTitle === "string" && itemTitle.length <= 300)) return res.status(400).json({ error: "Invalid item" });
    if (itemCount != null && !(Number.isInteger(itemCount) && itemCount >= 1 && itemCount <= 999)) return res.status(400).json({ error: "Invalid item count" });
    // An order this install already follows (under its UCP checkout) isn't
    // added again when the app later registers it by order id.
    if (sent == null && db.prepare("SELECT order_gid FROM tracked_orders WHERE device=? AND order_gid IS NOT NULL").all(req.device)
      .some((r) => r.order_gid.split("/").pop() === orderID.split("/").pop())) return res.status(201).json({ orders: list(req.device) });
    const open = db.prepare("SELECT COUNT(*) AS n FROM tracked_orders WHERE device=? AND done IS NULL").get(req.device).n;
    if (open >= MAX_OPEN) return res.status(429).json({ error: "Too many open orders" });
    db.prepare(`INSERT INTO tracked_orders(device, brand_id, checkout_id, order_gid, item_title, item_count, created) VALUES(?,?,?,?,?,?,?)
      ON CONFLICT(device, checkout_id) DO UPDATE SET order_gid=COALESCE(excluded.order_gid, order_gid),
        item_title=COALESCE(excluded.item_title, item_title), item_count=COALESCE(excluded.item_count, item_count)`)
      .run(req.device, brandID, id, orderID || null, itemPhrase(itemTitle, 1), itemCount ?? null, Date.now());
    // An order email that arrived before the app registered the order moves it now.
    try { onRegister(); } catch (e) { console.error("Order email sync failed:", e.name); }
    res.status(201).json({ orders: list(req.device) });
  });
  router.get("/", (req, res) => res.json({ orders: list(req.device) }));
  // Names the items of orders this install registered before the app sent
  // them (owner, 2026-10-09), matched by the Shopify order number.
  router.patch("/items", (req, res) => {
    const { orderID, itemTitle, itemCount } = req.body || {};
    if (typeof orderID !== "string" || !orderGID.test(orderID)) return res.status(400).json({ error: "Invalid order" });
    if (typeof itemTitle !== "string" || itemTitle.length > 300 || !itemPhrase(itemTitle, 1)) return res.status(400).json({ error: "Invalid item" });
    if (itemCount != null && !(Number.isInteger(itemCount) && itemCount >= 1 && itemCount <= 999)) return res.status(400).json({ error: "Invalid item count" });
    const number = orderID.split("/").pop();
    const rows = db.prepare("SELECT id, order_gid FROM tracked_orders WHERE device=?").all(req.device)
      .filter((r) => r.order_gid && r.order_gid.split("/").pop() === number);
    for (const r of rows) db.prepare("UPDATE tracked_orders SET item_title=?, item_count=? WHERE id=?").run(itemPhrase(itemTitle, 1), itemCount ?? null, r.id);
    res.json({ updated: rows.length });
  });
  // A tracking number the shopper added to one of their orders (owner,
  // 2026-10-13): the fallback when the wallet's email kept the brand's
  // shipping email from Marracat and its status page is behind a sign-in.
  // Only this install's rows, matched by the Shopify order number.
  router.put("/tracking", async (req, res) => {
    const { orderID, trackingNumber } = req.body || {};
    if (typeof orderID !== "string" || !orderGID.test(orderID)) return res.status(400).json({ error: "Invalid order" });
    const number = typeof trackingNumber === "string" ? trackingNumber.replace(/[\s-]/g, "").toUpperCase() : "";
    if (!/^[A-Z0-9]{8,35}$/.test(number)) return res.status(400).json({ error: "That doesn't look like a tracking number" });
    const key = orderID.split("/").pop();
    const rows = db.prepare("SELECT * FROM tracked_orders WHERE device=?").all(req.device)
      .filter((r) => r.order_gid && r.order_gid.split("/").pop() === key);
    if (!rows.length) return res.status(404).json({ error: "Order not found" });
    const carrier = carrierFor(number);
    for (const r of rows) {
      if (r.tracking_number === number) continue;
      db.prepare(`UPDATE tracked_orders SET tracking_number=?, carrier=?, tracking_url=?, tracker_id=NULL, tracking_status=NULL,
        state=CASE WHEN COALESCE(state,'confirmed')='confirmed' THEN 'shipped' ELSE state END, updated=?, done=NULL WHERE id=?`)
        .run(number, carrier, carrierTrackingURL(carrier, number), Date.now(), r.id);
      if (tracker) await startPageTracker(db, db.prepare("SELECT * FROM tracked_orders WHERE id=?").get(r.id), { tracker, budget });
    }
    res.json({ orders: list(req.device) });
  });
  // Deleting the account (or the app's "forget my orders") drops this install's
  // rows, and its guest order email with what it received.
  router.delete("/", (req, res) => { deleteTrackedOrders(db, req.device); res.json({ orders: [] }); });
  router.use((error, req, res, next) => {
    res.status(error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500).json({ error: "Request could not be completed" });
  });
  app.use("/api/orders/tracked", router);

  if (schedule) {
    let running = false;
    const run = async () => {
      if (running) return;
      running = true;
      try {
        const r = await checkTrackedOrders(db, { apns, lookup, fetcher, tracker, budget });
        if (r.orders) console.log(`Order tracking: ${r.orders} checked, ${r.resolved} resolved, ${r.read} pages read, ${r.moved} moved`);
      } catch (e) { console.error("Order tracking failed:", e.name); } finally { running = false; }
    };
    setTimeout(run, 90_000).unref();
    setInterval(run, TRACK_EVERY_MS).unref();
  }
  return { track17Update: (payload) => track17Update(db, payload, { apns, lookup }),
    easyPostUpdate: (payload) => easyPostUpdate(db, payload, { apns, lookup }) };
}

// Account deletion is per account; tracked orders are per install. The app
// clears its own list and this drops the server's for that device.
export function deleteTrackedOrders(db, deviceHash) {
  db.prepare("DELETE FROM tracked_orders WHERE device=?").run(deviceHash);
  if (db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='relay_addresses'").get()) deleteRelayData(db, guestOwner(deviceHash));
}
