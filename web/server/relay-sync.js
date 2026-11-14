import { orderKey, stepForTrackerStatus } from "./relay.js";
import { carrierTrackingURL } from "./order-tracking.js";

// Order emails move the app's tracked orders (owner, 2026-10-13: KOBA's
// tracked order #3 stayed "confirmed" while its order email had it
// delivered).
//
// The relay (relay.js) and the order-page tracker (order-tracking.js) each
// follow an order on their own: relay_events per account or guest install,
// tracked_orders per install. This links each tracked order to the order
// number its brand's emails use and carries the furthest step, the tracking
// number and the expected day across, forward only. It never pushes: the
// relay already notified for each email and tracker step, and a linked
// order's own pushes claim the relay's key for that step (order-tracking.js
// pushStep), so a phone hears each step once whichever side saw it first.
//
// Which tracked order an email belongs to: the one with the same tracking
// number, else the one whose item the email names (when only one order
// number names it), else by time the way the app's RelayStore decides — the
// brand's orders on that account's phones in the order they were placed, each
// claiming the first unclaimed order number confirmed (or, failing that,
// named) between an hour before it was placed and the brand's next order.

const DAY = 86400_000;
const LOOKBACK = 60 * DAY;
const STEPS = ["confirmed", "shipped", "out_for_delivery", "delivered"];
const KIND_STEP = { confirmation: "confirmed", shipped: "shipped", out_for_delivery: "out_for_delivery", delivered: "delivered" };
const rank = (s) => STEPS.indexOf(s);
const has = (db, t) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(t);

/// The phones (device hashes) an order-email owner shops on: a guest install
/// is its own, an account every phone signed in to it or that set up its address.
export function devicesFor(db, owner) {
  if (owner.startsWith("device:")) return [owner.slice("device:".length)];
  const out = new Set();
  if (has(db, "restock_links")) for (const r of db.prepare("SELECT device FROM restock_links WHERE user_id=?").all(owner)) out.add(r.device);
  for (const r of db.prepare("SELECT device FROM relay_addresses WHERE user_id=? AND device IS NOT NULL").all(owner)) out.add(r.device);
  return [...out];
}

/// The furthest step a set of one order's emails reached (problems don't
/// count as a step), and its latest tracking.
export function relayProgress(events) {
  let step = null;
  let tracking = null;
  for (const e of events) {
    for (const s of [KIND_STEP[e.kind], stepForTrackerStatus(e.tracking_status)])
      if (s && s !== "problem" && rank(s) > rank(step)) step = s;
    if (e.tracking_number && (!tracking || e.received >= tracking.received)) tracking = e;
  }
  return { step, tracking };
}

export function syncRelayOrders(db, { brandFor = () => null, now = Date.now, log = () => {} } = {}) {
  if (!has(db, "relay_events") || !has(db, "tracked_orders")) return 0;
  const t = now();
  let changed = 0;
  const owners = db.prepare("SELECT DISTINCT user_id FROM relay_events WHERE received > ? AND brand_domain IS NOT NULL").all(t - LOOKBACK).map((r) => r.user_id);
  for (const owner of owners) {
    const devices = devicesFor(db, owner);
    if (!devices.length) continue;
    const byBrand = new Map();
    for (const e of db.prepare("SELECT * FROM relay_events WHERE user_id=? AND received > ? AND brand_domain IS NOT NULL ORDER BY received, id").all(owner, t - LOOKBACK)) {
      const id = brandFor(e.brand_domain)?.id;
      if (!id) continue;
      if (!byBrand.has(id)) byBrand.set(id, []);
      byBrand.get(id).push(e);
    }
    const marks = devices.map(() => "?").join(",");
    for (const [brandID, events] of byBrand) {
      const rows = db.prepare(`SELECT * FROM tracked_orders WHERE device IN (${marks}) AND brand_id=? ORDER BY created, id`).all(...devices, brandID);
      if (!rows.length) continue;
      // One order registered on two phones (or by checkout and by order id)
      // is one order: rows sharing a Shopify order number go together.
      const groups = [];
      for (const r of rows) {
        const n = r.order_gid ? r.order_gid.split("/").pop() : null;
        const g = n && groups.find((x) => x.number === n);
        if (g) g.rows.push(r); else groups.push({ number: n, created: r.created, rows: [r] });
      }
      const linkOf = (g) => g.rows.find((r) => r.relay_owner === owner && r.relay_order)?.relay_order || null;
      for (const g of groups) g.link = linkOf(g);
      const claimed = new Set(groups.map((g) => g.link).filter(Boolean).map((l) => l.split("|").pop()));
      const named = events.filter((e) => e.order_name);
      const claim = (g, e) => { g.link = `${e.brand_domain || ""}|${orderKey(e.order_name)}`; claimed.add(orderKey(e.order_name)); };
      // Proof first: the same tracking number, then the same item named in
      // the email and in the app's order (only when one order number has it).
      for (const g of groups.filter((x) => !x.link)) {
        const numbers = new Set(g.rows.map((r) => r.tracking_number).filter(Boolean));
        const hit = named.find((e) => e.tracking_number && numbers.has(e.tracking_number) && !claimed.has(orderKey(e.order_name)));
        if (hit) claim(g, hit);
      }
      for (const g of groups.filter((x) => !x.link)) {
        const items = new Set(g.rows.map((r) => r.item_title).filter(Boolean));
        const hits = named.filter((e) => e.item_title && items.has(e.item_title) && !claimed.has(orderKey(e.order_name)));
        if (hits.length && new Set(hits.map((e) => orderKey(e.order_name))).size === 1) claim(g, hits[0]);
      }
      // Then by time, as the app does.
      groups.forEach((g, i) => {
        if (!g.link) {
          const start = Math.max(g.created - 3600_000, i > 0 ? groups[i - 1].created : -Infinity);
          const end = i + 1 < groups.length ? groups[i + 1].created : Infinity;
          const open = named.filter((e) => e.received >= start && e.received < end && !claimed.has(orderKey(e.order_name)));
          const pick = open.find((e) => e.kind === "confirmation") || open[0];
          if (pick) claim(g, pick);
        }
      });
      groups.forEach((g) => {
        const link = g.link;
        if (!link) return;
        const key = link.split("|").pop();
        const mine = events.filter((e) => e.order_name && orderKey(e.order_name) === key);
        const { step, tracking } = relayProgress(mine);
        for (const r of g.rows) changed += apply(db, r, { owner, link, step, tracking, now: t, log });
      });
    }
  }
  return changed;
}

function apply(db, row, { owner, link, step, tracking, now, log }) {
  const was = row.state || "confirmed";
  const next = step && rank(step) > rank(was) ? step : was;
  const fill = tracking && !row.tracking_number;
  const sameTracker = tracking?.tracker_id && (row.tracker_id === tracking.tracker_id || (fill && !row.tracker_id));
  const update = {
    relay_owner: owner, relay_order: link, state: next,
    carrier: fill ? tracking.carrier : row.carrier,
    tracking_number: fill ? tracking.tracking_number : row.tracking_number,
    tracking_url: fill && !row.tracking_url ? carrierTrackingURL(tracking.carrier, tracking.tracking_number) : row.tracking_url,
    tracker_id: fill && !row.tracker_id ? tracking.tracker_id : row.tracker_id,
    tracking_status: sameTracker && tracking.tracking_status ? tracking.tracking_status : row.tracking_status,
    est_delivery: (tracking?.est_delivery && (fill || sameTracker)) ? tracking.est_delivery : row.est_delivery,
    updated: next !== was ? now : row.updated,
    done: next === "delivered" ? (row.done || now) : row.done,
  };
  const dirty = Object.keys(update).some((k) => (update[k] ?? null) !== (row[k] ?? null));
  if (!dirty) return 0;
  db.prepare(`UPDATE tracked_orders SET relay_owner=@relay_owner, relay_order=@relay_order, state=@state, carrier=@carrier,
    tracking_number=@tracking_number, tracking_url=@tracking_url, tracker_id=@tracker_id, tracking_status=@tracking_status,
    est_delivery=@est_delivery, updated=@updated, done=@done WHERE id=@id`).run({ ...update, id: row.id });
  if (next !== was) log(`Order tracking #${row.id} (${row.brand_id}): ${was} -> ${next} [order email]`);
  return 1;
}
