#!/usr/bin/env node
// The weekly website + app report from site_events (events.js) and visits.
//
//   DATA_DIR=/var/lib/marracat node /opt/marracat-web/current/server/events-report.js [--days 7] [--json]
//
// Read-only: opens the database without writing.
import path from "node:path";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { eventReport } from "./events.js";
import { freshReport } from "./brand-fresh.js";
import { vitalsReport } from "./vitals.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const days = Math.max(1, Math.min(180, Number(args[args.indexOf("--days") + 1]) || 7));
const file = path.join(process.env.DATA_DIR || path.join(here, "../data"), "marracat.sqlite");
const db = new Database(file, { readonly: true, fileMustExist: true });
let report;
try {
  report = eventReport(db, { days });
} catch (e) {
  // A fresh database has no site_events table until the server first runs.
  if (!/no such table/.test(e.message)) throw e;
  report = { window: { days }, note: "no events recorded yet" };
}
// Faster refresh for brands a shopper keeps coming back to: is it catching
// anything the 3-hour catalog doesn't (owner, 2026-10-21)?
try {
  const since = new Date(Date.now() - days * 86_400_000).toISOString().slice(0, 10);
  report.fresh_refresh = freshReport(db, since);
} catch (e) {
  if (!/no such table/.test(e.message)) throw e;
}
// How fast the website was for real visitors (server/vitals.js).
try {
  report.speed = vitalsReport(db, { days });
} catch (e) {
  if (!/no such table/.test(e.message)) throw e;
}
db.close();

const SPEED_NAMES = { ttfb: "server answer", fcp: "first paint", lcp: "main content shown", inp: "slowest tap", cls: "layout shift", catalog: "catalog ready" };
function speedLines(v) {
  if (!v?.loads) return [];
  return [`Website speed, real visits (${v.loads} loads · ${v.repeat} repeat visits · ${v.installed} from the installed app):`,
    ...Object.entries(v.measures).map(([m, x]) => `  ${SPEED_NAMES[m]}: ${x.good_pct}% good · ${x.poor_pct}% poor (${x.loads} loads; ${Object.entries(x.ranges).map(([r, n]) => `${r}: ${n}`).join(", ")})`),
    ...(Object.keys(v.catalog_from).length ? [`  catalog came from: ${Object.entries(v.catalog_from).map(([k, n]) => `${k} ${n}`).join(" · ")}`] : [])];
}

function freshLines(f) {
  if (!f) return [];
  if (!f.asks) return ["Faster brand refresh: no phone asked yet"];
  const pct = (n, d) => (d ? `${Math.round((100 * n) / d)}%` : "–");
  return [`Faster brand refresh: ${f.asks} asks from phones for ${f.brands} brands · ${f.fetches} store fetches (${pct(f.asks - f.fetches, f.asks)} served from cache) · ${f.failures} failed`,
    `  ${f.changed} fetches (${pct(f.changed, f.fetches - f.failures)}) caught something the catalog didn't show: ${f.price} price, ${f.stock} stock, ${f.added} new products`,
    ...f.by_brand.map((b) => `  ${b.brand}: ${b.asks} asks · ${b.fetches} fetches · ${b.changed} with a change (${b.price} price, ${b.stock} stock, ${b.added} new)`)];
}
// Recommendation rows (app + website): shown, tapped, tap rate, people.
function recLines(label, rows) {
  if (!rows) return [];
  if (!rows.length) return [`Recommendation rows, ${label}: none recorded`];
  const pct = (r) => (r.tap_rate == null ? "–" : `${(r.tap_rate * 100).toFixed(1)}%`);
  return [`Recommendation rows, ${label}:`,
    ...rows.map((r) => `  ${r.row} (${r.platform}): ${r.views} views · ${r.taps} taps · ${pct(r)} tap rate · ${r.visitors} people`)];
}

// The addendum sections: funnel by platform, people, screens, engagement,
// sign-in, notifications, checkouts.
function platformLines(r) {
  const out = [];
  for (const [p, f] of Object.entries(r.funnel_by_platform || {}))
    out.push(`Funnel, ${p} (people): opened ${f.opened} → product ${f.viewed_a_product} → cart ${f.added_to_cart} → checkout ${f.started_checkout} → completed ${f.completed_checkout}`);
  for (const [p, x] of Object.entries(r.people || {}))
    out.push(`People, ${p}: ${x.people} in window · DAU today ${x.dau_today} (avg ${x.dau_average}) · WAU ${x.wau} · came back on 2+ days ${x.came_back_on_2plus_days} · returning from before ${x.returning_from_before} · signed in ${x.signed_in_people} · guests ${x.guests} · accounts ${x.accounts}`);
  const list = (title, rows, fmt) => (rows?.length ? [title, ...rows.map((x) => "  " + fmt(x))] : []);
  out.push(...list("Top screens:", r.top_screens, (x) => `${x.views}× ${x.screen} (${x.platform}, ${x.people} people)`));
  const eng = Object.entries(r.engagement || {}).filter(([, v]) => v.events);
  if (eng.length) out.push("Saves, follows, alerts, lists, shares:", ...eng.map(([n, v]) => `  ${n}: ${v.events} (${v.people} people)`));
  out.push(...list("Alerts by kind:", r.alerts_by_kind, (x) => `${x.kind}: ${x.turned_on} on · ${x.turned_off} off`));
  out.push(...list("Sign-in funnel:", r.sign_in, (x) => `${x.provider}: started ${x.started} → signed in ${x.signed_in} · new accounts ${x.signed_up}`));
  out.push(...list("Notification opens:", r.notification_opens, (x) => `${x.opens}× ${x.kind} (${x.people} people)`));
  out.push(...list("Banners (views → taps):", r.banners, (x) => `${x.kind} ${x.brand}: ${x.views} → ${x.taps} (${x.people} people)`));
  out.push(...list("Checkouts:", r.checkouts, (x) => `${x.name} via ${x.via}: ${x.n} (${x.people} people)`));
  out.push(...list("People we know (counted above too):", r.known_people, (x) =>
    `${x.name || "unnamed"} (${x.kind}, ${x.platforms}): ${x.days} days, last ${x.last_day} · ${x.searches} searches · ${x.product_views} products · ${x.added_to_cart} to cart · ${x.checkouts} checkouts`));
  return out;
}

if (args.includes("--json")) {
  console.log(JSON.stringify(report, null, 2));
} else {
  const f = report.funnel || {};
  const lines = [
    `Marracat website and app, ${report.window.since ?? "?"} → ${report.window.until ?? "?"} (${days} days)`,
    report.visitors ? `Visitors: ${report.visitors.web_visitors} · returning ${report.visitors.returning_from_before} · came back on 2+ days ${report.visitors.came_back_on_2plus_days}` : "",
    `Website funnel (visitors): searched ${f.searched ?? 0} · opened a product ${f.opened_a_product ?? 0} · added to cart ${f.added_to_cart ?? 0} · clicked Buy ${f.clicked_buy ?? 0}`,
    ...platformLines(report),
    "Top searches:", ...(report.searches || []).map((s) => `  ${s.searches}× "${s.q}"${s.no_results ? ` (${s.no_results} with no results)` : ""}`),
    "Buy clicks by brand:", ...(report.buy_clicks_by_brand || []).map((b) => `  ${b.clicks}× ${b.brand} (${b.visitors} visitors)`),
    "Most-opened products:", ...(report.products_opened || []).map((p) => `  ${p.opens}× ${p.product}`),
    ...recLines("last 7 days", report.recommendation_rows?.last_7_days),
    ...recLines("last 30 days", report.recommendation_rows?.last_30_days),
    ...freshLines(report.fresh_refresh),
    ...speedLines(report.speed),
  ];
  console.log(lines.filter((l) => l !== "").join("\n"));
}
