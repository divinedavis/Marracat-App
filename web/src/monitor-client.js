// The website's half of the owner dashboard's Monitor page (server/monitor.js,
// owner 2026-11-15). Sends, in batches to POST /api/monitor:
//   tap     a button or link pressed: its visible label (or aria-label), and
//           the screen it was on. Never what's typed into a field.
//   screen  each page change, as the app's screen names.
//   api     every call to our own /api and /auth: method, route, status and
//           how long it took as the shopper waited for it.
//   error   script errors and unhandled promise rejections.
// The visitor is the same random id the visit count keeps; the server stores
// only an HMAC of it. The owner's browser is flagged, not dropped, so its
// errors still show when the page is asked to include them.

const ENDPOINT = "/api/monitor";
const SKIP = /^\/api\/(monitor|events|vitals|visit)\b/;
const MAX_QUEUE = 300;
let queue = [];
let screen = null;
let started = false;
let timer = null;

function visitorID() {
  try {
    let id = localStorage.getItem("marracat-visitor");
    if (!id) { id = crypto.randomUUID(); localStorage.setItem("marracat-visitor", id); }
    return id;
  } catch { return null; }
}
function sessionID() {
  try {
    let s = sessionStorage.getItem("marracat-monitor-session");
    if (!s) { s = crypto.randomUUID().replace(/-/g, "").slice(0, 16); sessionStorage.setItem("marracat-monitor-session", s); }
    return s;
  } catch { return null; }
}
const isOwner = () => { try { return localStorage.getItem("marracat-owner") === "1"; } catch { return false; } };

function push(ev) {
  if (!started) return;
  ev.t = Date.now();
  if (screen && !ev.sc) ev.sc = screen;
  queue.push(ev);
  if (queue.length > MAX_QUEUE) queue = queue.slice(-MAX_QUEUE);
  if (queue.length >= 40) flush();
}

export function flush(useBeacon = false) {
  if (!queue.length) return;
  const id = visitorID();
  if (!id) { queue = []; return; }
  const batch = queue.splice(0, 100);
  const body = JSON.stringify({ id, s: sessionID(), now: Date.now(), o: isOwner() ? 1 : undefined, ev: batch });
  try {
    if (useBeacon && navigator.sendBeacon?.(ENDPOINT, new Blob([body], { type: "application/json" }))) return;
    origFetch?.(ENDPOINT, { method: "POST", keepalive: true, headers: { "Content-Type": "application/json" }, body }).catch(() => {});
  } catch { /* a lost batch is fine */ }
  if (queue.length) flush(useBeacon);
}

/// The label a person saw on what they pressed, kept short.
export function labelOf(el) {
  const own = el.getAttribute("data-monitor") || el.getAttribute("aria-label") || el.getAttribute("title");
  let t = own || el.innerText || el.textContent || el.getAttribute("value") || "";
  t = String(t).replace(/\s+/g, " ").trim();
  if (!t) {
    const img = el.querySelector?.("img[alt]");
    t = img?.getAttribute("alt") || el.id || el.getAttribute("href") || "";
  }
  return t.slice(0, 80);
}

const TAPPABLE = 'button, a[href], [role="button"], [role="tab"], [role="menuitem"], summary, input[type="checkbox"], input[type="radio"], input[type="submit"], select';

let origFetch = null;
function wrapFetch() {
  if (origFetch || typeof window.fetch !== "function") return;
  origFetch = window.fetch.bind(window);
  window.fetch = async (input, init) => {
    let url;
    try { url = new URL(typeof input === "string" ? input : input.url, location.href); } catch { return origFetch(input, init); }
    if (url.origin !== location.origin || !/^\/(api|auth)\//.test(url.pathname) || SKIP.test(url.pathname)) return origFetch(input, init);
    const method = String(init?.method || (typeof input !== "string" && input.method) || "GET").toUpperCase();
    const t0 = performance.now();
    try {
      const res = await origFetch(input, init);
      const ev = { k: "api", n: url.pathname, m: method, st: res.status, ms: Math.round(performance.now() - t0) };
      if (res.status >= 500) ev.msg = `${method} ${url.pathname} answered ${res.status}`;
      push(ev);
      return res;
    } catch (e) {
      // An aborted request was cancelled on purpose (a newer search), not a failure.
      if (e?.name !== "AbortError")
        push({ k: "api", n: url.pathname, m: method, st: 0, ms: Math.round(performance.now() - t0), msg: `${method} ${url.pathname}: ${e?.name || "network error"}` });
      throw e;
    }
  };
}

/// The page changed: remember it for taps, and send it once.
export function monitorScreen(name) {
  if (!name || name === screen) return;
  screen = name;
  push({ k: "screen", n: name, sc: name });
}

export function startMonitor() {
  if (started || typeof window === "undefined") return;
  started = true;
  wrapFetch();
  document.addEventListener("click", (e) => {
    const el = e.target?.closest?.(TAPPABLE);
    if (!el || el.closest("[data-monitor-skip]")) return;
    const n = labelOf(el);
    if (n) push({ k: "tap", n });
  }, true);
  window.addEventListener("error", (e) => {
    const where = e.filename ? ` (${String(e.filename).split("/").pop()}:${e.lineno || 0})` : "";
    push({ k: "error", n: "js", msg: String(e.message || "Script error") + where });
  });
  window.addEventListener("unhandledrejection", (e) => {
    const r = e.reason;
    push({ k: "error", n: "promise", msg: String(r?.message || r || "Unhandled rejection") });
  });
  timer = setInterval(() => flush(), 5000);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") flush(true); });
  window.addEventListener("pagehide", () => flush(true));
}

/// For tests.
export const _queue = () => queue;
export function _reset() { queue = []; screen = null; started = false; if (timer) clearInterval(timer); if (origFetch) { window.fetch = origFetch; origFetch = null; } }
