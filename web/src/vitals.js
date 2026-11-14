// How fast this visit was, from the browser's own timings, sent once as the
// page is left (server/vitals.js keeps each as a range, with no visitor id).
// The owner's browser never sends, like the visit count.
//
// Not every browser reports every measure (layout shift and interaction
// delay are Chromium's; Safari gives first paint and, from 26, largest
// paint): what is missing is left out.

const marks = {};
/// A timing the page itself knows: when the catalog became usable, and where
/// it came from ("device", "network", or "page" for the old in-page download).
export function markCatalog(from) {
  if (marks.catalog !== undefined) return;
  marks.catalog = performance.now() / 1000;
  marks.catalog_from = from;
  note("marracat:catalog", from);
}
/// The same facts on the browser's own performance timeline, where the
/// developer tools show them (and the journeys read them).
function note(name, detail) {
  try {
    performance.mark(name, { detail });
  } catch {
    /* an old browser's mark() takes no detail */
  }
}

/// Layout shift as the browser scores it: the worst burst of shifts, where a
/// burst ends after a 1 s pause or 5 s (web.dev/cls). Shifts just after the
/// visitor's own input don't count.
export function shiftScore(entries) {
  let worst = 0, burst = 0, first = 0, last = 0;
  for (const e of entries) {
    if (e.hadRecentInput) continue;
    if (burst && e.startTime - last < 1000 && e.startTime - first < 5000) burst += e.value;
    else { burst = e.value; first = e.startTime; }
    last = e.startTime;
    worst = Math.max(worst, burst);
  }
  return worst;
}

/// Whether the page got its search index from the worker (not stored by the
/// server; the journeys read it to know the index is really in use).
export function markIndexed(ok) {
  marks.indexed = !!ok;
  note("marracat:index", !!ok);
}

export function watchVitals({ screen = () => undefined, send } = {}) {
  if (typeof PerformanceObserver === "undefined") return;
  try {
    if (localStorage.getItem("marracat-owner") === "1") return;
  } catch {
    return;
  }
  const v = {}, shifts = [];
  const observe = (type, read, more = {}) => {
    try {
      new PerformanceObserver((list) => read(list.getEntries())).observe({ type, buffered: true, ...more });
    } catch {
      /* this browser doesn't report that measure */
    }
  };
  observe("paint", (es) => { for (const e of es) if (e.name === "first-contentful-paint") v.fcp = e.startTime; });
  observe("largest-contentful-paint", (es) => { if (es.length) v.lcp = es[es.length - 1].startTime; });
  observe("layout-shift", (es) => { shifts.push(...es); });
  // The slowest tap, click or key press to show its result.
  observe("event", (es) => { for (const e of es) if (e.interactionId) v.inp = Math.max(v.inp || 0, e.duration); }, { durationThreshold: 40 });
  let sent = false;
  const flush = () => {
    if (sent || document.visibilityState !== "hidden") return;
    sent = true;
    const nav = performance.getEntriesByType?.("navigation")[0];
    if (nav?.responseStart > 0) v.ttfb = nav.responseStart;
    if (shifts.length) v.cls = shiftScore(shifts);
    const body = JSON.stringify({
      ...v, ...marks, screen: screen(),
      conn: navigator.connection?.effectiveType,
      installed: matchMedia("(display-mode: standalone)").matches || navigator.standalone === true,
      // A visit whose script came from the browser's cache has been here before.
      repeat: nav ? nav.transferSize === 0 && nav.decodedBodySize > 0 : undefined,
    });
    if (send) return send(body);
    if (!navigator.sendBeacon?.("/api/vitals", new Blob([body], { type: "application/json" })))
      fetch("/api/vitals", { method: "POST", keepalive: true, headers: { "Content-Type": "application/json" }, body }).catch(() => {});
  };
  document.addEventListener("visibilitychange", flush);
  addEventListener("pagehide", flush);
}
