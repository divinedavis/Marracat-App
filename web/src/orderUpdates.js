// Which shipping updates belong to which order, the way the app decides
// (Marracat/Stores/RelayStore.swift `events(for:)`, OrderTrackingStore.swift
// `tracked(for:)`), for the website's order details (owner, 2026-10-11).
import { fromAppleDate } from "./orderRecord.js";

export const STEP_NAMES = ["Ordered", "Shipped", "Out for delivery", "Delivered"];
const STEP_KINDS = ["", "shipped", "out_for_delivery", "delivered"];

/// One order number however the brand wrote it: "#KOBA-11906", "11906" and
/// "#11906" are all "11906".
export function orderKey(name) {
  const s = String(name).toLowerCase().replaceAll("#", "").trim();
  const dash = s.lastIndexOf("-");
  if (dash > 0 && /^[a-z]+$/.test(s.slice(0, dash)) && dash < s.length - 1) return s.slice(dash + 1);
  return s;
}

/// The number at the end of a Shopify order id ("gid://shopify/Order/123?key=…").
export const orderNumber = (gid) => (gid ? String(gid).split("/").pop().split("?")[0] || null : null);

const strip = (d) => String(d).toLowerCase().replace(/^www\./, "");

export function sameBrand(event, brand) {
  if (!brand) return false;
  if (event.brandDomain) {
    const d = strip(event.brandDomain), b = strip(brand.domain || "");
    return !!b && (d === b || d.endsWith("." + b) || b.endsWith("." + d));
  }
  return !!event.brandName && event.brandName.toLowerCase() === (brand.name || "").toLowerCase();
}

const placedAt = (record) => fromAppleDate(record.date).getTime();

/// The brand's emails about this order: those from when it was placed until
/// the brand's next order, narrowed to its order number once one names it. A
/// number an earlier order of the brand already claimed is never this one's.
export function relayEventsFor(record, brand, allOrders, events) {
  const mine = events.filter((e) => sameBrand(e, brand));
  if (!mine.length) return [];
  const orders = allOrders.filter((o) => o.brandID === record.brandID).sort((a, b) => placedAt(a) - placedAt(b));
  const claimed = new Set();
  for (let i = 0; i < orders.length; i++) {
    const start = Math.max(placedAt(orders[i]) - 3600_000, i > 0 ? placedAt(orders[i - 1]) : -Infinity);
    const next = i + 1 < orders.length ? placedAt(orders[i + 1]) : Infinity;
    const window = mine.filter((e) => e.received >= start && e.received < next);
    const open = (e) => (e.orderName ? !claimed.has(orderKey(e.orderName)) : false);
    const byDate = [...window].sort((a, b) => a.received - b.received);
    const first = byDate.find((e) => e.kind === "confirmation" && open(e)) || byDate.find(open);
    const name = first?.orderName ? orderKey(first.orderName) : null;
    if (orders[i].id === record.id) {
      if (!name) return window.filter((e) => !e.orderName || open(e));
      return mine.filter((e) => (e.orderName ? orderKey(e.orderName) === name : window.includes(e)));
    }
    if (name) claimed.add(name);
  }
  return [];
}

/// The order the server follows on the brand's own order page.
export function trackedFor(record, tracked) {
  const n = orderNumber(record.orderID);
  if (!n) return null;
  return tracked.find((t) => t.brandID === record.brandID && orderNumber(t.orderID) === n) || null;
}

/// Everything known about one order's shipping, oldest first.
export function updatesFor(record, brand, allOrders, { events = [], tracked = [] } = {}) {
  const t = trackedFor(record, tracked);
  const list = relayEventsFor(record, brand, allOrders, events).map((e) => ({ ...e }));
  if (t && ["shipped", "out_for_delivery", "delivered"].includes(t.state))
    list.push({ id: `t${t.created}`, received: t.updated || t.created, kind: t.state, carrier: t.carrier, trackingNumber: t.trackingNumber });
  list.sort((a, b) => a.received - b.received);
  return { events: list, tracked: t };
}

/// 0 ordered, 1 shipped, 2 out for delivery, 3 delivered.
export function stepOf(events) {
  return events.reduce((best, e) => Math.max(best, STEP_KINDS.indexOf(e.kind), STEP_KINDS.indexOf(e.trackingStep || "")), 0);
}

const day = (ms) => new Date(ms).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });

export function headline(step, events, placedMs) {
  const kind = STEP_KINDS[Math.min(step, 3)];
  const when = [...events].reverse().find((e) => e.kind === kind || e.trackingStep === kind)?.received ?? placedMs;
  if (step >= 3) return `Delivered ${day(when)}`;
  if (step === 2) return "Out for delivery";
  if (step === 1) return `Shipped ${day(when)}`;
  return `Ordered ${day(placedMs)}`;
}

/// "Arriving today", "Arriving tomorrow", "Arriving Friday, Oct 16"; nothing for a past day.
export function arrivalLabel(isoDay, now = new Date()) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDay || "");
  if (!m) return null;
  const date = new Date(+m[1], +m[2] - 1, +m[3]);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const diff = Math.round((date - today) / 86400_000);
  if (diff < 0) return null;
  if (diff === 0) return "Arriving today";
  if (diff === 1) return "Arriving tomorrow";
  return "Arriving " + date.toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric" });
}

export function carrierName(c) {
  return { USPS: "USPS", UPS: "UPS", FedEx: "FedEx", DHLExpress: "DHL" }[c] || "Carrier";
}

/// A plain-words line for one update in the history.
export function describe(e) {
  const what = {
    confirmation: "Order confirmed", confirmed: "Order confirmed", shipped: "Shipped",
    out_for_delivery: "Out for delivery", delivered: "Delivered", cancelled: "Cancelled", refund: "Refund issued",
  }[e.trackingStep && e.trackingStep !== e.kind ? e.trackingStep : e.kind] || "Update from the brand";
  return e.carrier && (e.kind === "shipped" || e.trackingNumber) ? `${what} · ${carrierName(e.carrier)}` : what;
}

/// Only https links leave the site (a brand's status page, a carrier's tracker).
export const safeLink = (u) => {
  try { return new URL(u).protocol === "https:" ? u : null; } catch { return null; }
};
