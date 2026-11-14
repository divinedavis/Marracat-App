import { rateLimit } from "express-rate-limit";
import { getDomain } from "tldts";
import { readText } from "./store-fetch.js";
import { productRecord, brandRecord } from "./catalog.js";
import { watchable } from "./restock.js";
import { fetchLimiter } from "./complements.js";

// Live stock for a product page (owner, 2026-10-11). A "Back in stock" push
// went out for a Sienna Naturals pre-order the brand's store had just turned
// on, and tapping it opened a page that said "Currently unavailable": the
// page read stock from the catalog, refreshed about every 12 hours, and the
// phone's copy predated the restock. Pages now ask here, and this asks the
// brand's own Shopify store (/products/<handle>.js, the same JSON the restock
// check reads) and answers with each option's availability and price.
//
// Shopify only, and only the store URL our own catalog has for the product
// (https, /products/<handle>, no port, no IP literal), so this can't be
// pointed anywhere else. One answer per product is shared by every shopper for
// CACHE_MS; a failed fetch is remembered for FAIL_CACHE_MS so a down store
// isn't asked again on every page view. At most GLOBAL_CONCURRENCY fetches run
// at once, one per store, and the route is rate limited per address. Anything
// that doesn't work answers { live: false } and the page keeps the catalog's
// stock, which is what it showed before.

export const CACHE_MS = 90_000;
export const FAIL_CACHE_MS = 30_000;
export const FETCH_TIMEOUT_MS = 4000;
export const MAX_ENTRIES = 5000;
const MAX_BODY = 2_000_000;
const ID = /^[a-z0-9][a-z0-9_-]{0,159}$/i;
const IP_LITERAL = /^(\d+(\.\d+){3}|\[.*\])$/;

/// The live-JSON URL for a catalog product, or null when it has none we trust.
export function liveStockTarget(productID, lookup = { productRecord, brandRecord }) {
  const target = watchable(productID, lookup);
  if (!target) return null;
  const url = new URL(target.url);
  if (url.port || url.username || url.password || IP_LITERAL.test(url.hostname) || !url.hostname.includes(".")) return null;
  const product = lookup.productRecord(productID);
  return { url: url.toString(), host: url.hostname, currency: product?.currency || "USD" };
}

/// One GET, following at most one redirect, and only to the same store
/// (or its myshopify.com address) and still a /products/<handle>.js path.
async function getLiveJSON(url, fetchImpl) {
  const host = new URL(url).hostname;
  let target = url;
  for (let hop = 0; hop < 2; hop++) {
    const res = await fetchImpl(target, {
      redirect: "manual", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      headers: { Accept: "application/json", "User-Agent": "Marracat/1.0 (+https://marracat.com)" },
    });
    if (res.status >= 300 && res.status < 400) {
      if (hop) return null;
      let next;
      try { next = new URL(res.headers.get("location") || "", target); } catch { return null; }
      const ok = next.protocol === "https:" && !next.port && !IP_LITERAL.test(next.hostname) &&
        /^\/products\/[^/]+\.js$/.test(next.pathname) &&
        (getDomain(next.hostname) === getDomain(host) || next.hostname.endsWith(".myshopify.com"));
      if (!ok) return null;
      target = next.toString();
      continue;
    }
    if (!res.ok) return null;
    const text = await readText(res, MAX_BODY);
    if (text == null) return null;
    try { return JSON.parse(text); } catch { return null; }
  }
  return null;
}

const cents = (v) => (Number.isFinite(v) && v >= 0 ? Math.round(v) / 100 : null);

/// What a page needs from the store's product JSON: each option's stock and,
/// for dollar products, its price (the store's JSON is in cents, and in the
/// shopper's currency, so other currencies keep the catalog's price).
export function liveStockFrom(live, { currency = "USD" } = {}) {
  if (!live || !Array.isArray(live.variants)) return null;
  const withPrice = currency === "USD";
  const variants = [];
  for (const v of live.variants) {
    const id = Number(v?.id);
    if (!Number.isSafeInteger(id) || id <= 0) continue;
    const out = { id, title: typeof v.title === "string" ? v.title.slice(0, 200) : "", available: v.available === true };
    if (withPrice) {
      const price = cents(v.price);
      const compare = cents(v.compare_at_price);
      if (price != null) out.price = price;
      out.compare_at = compare != null && price != null && compare > price ? compare : null;
    }
    variants.push(out);
    if (variants.length >= 250) break;
  }
  if (!variants.length) return null;
  return { available: live.available === true || variants.some((v) => v.available), variants };
}

export function liveStock({ lookup = { productRecord, brandRecord }, fetchImpl = fetch, now = Date.now, limiter = fetchLimiter() } = {}) {
  const cache = new Map();   // id -> { at, value }, oldest first
  const inflight = new Map();
  const remember = (id, value) => {
    cache.delete(id);
    cache.set(id, { at: now(), value });
    while (cache.size > MAX_ENTRIES) cache.delete(cache.keys().next().value);
  };
  async function get(id) {
    const target = liveStockTarget(id, lookup);
    if (!target) return null;
    const hit = cache.get(id);
    if (hit && now() - hit.at < (hit.value ? CACHE_MS : FAIL_CACHE_MS)) return hit.value;
    if (!inflight.has(id)) {
      inflight.set(id, limiter(target.host, () => getLiveJSON(target.url, fetchImpl))
        .catch(() => null)
        .then((json) => {
          const value = liveStockFrom(json, target);
          if (value) value.checked_at = new Date(now()).toISOString();
          remember(id, value);
          return value;
        })
        .finally(() => inflight.delete(id)));
    }
    return inflight.get(id);
  }
  /// The restock check has just read the same JSON; share it, so the page a
  /// "Back in stock" push opens agrees with the push.
  function prime(id, json) {
    const target = liveStockTarget(id, lookup);
    const value = target && liveStockFrom(json, target);
    if (value) { value.checked_at = new Date(now()).toISOString(); remember(id, value); }
  }
  return { get, prime };
}

export function liveStockRoutes(app, { stock = liveStock(), lookup = { productRecord, brandRecord }, limit = 60 } = {}) {
  app.get("/api/products/:id/stock",
    rateLimit({ windowMs: 60_000, limit, standardHeaders: "draft-8", legacyHeaders: false }),
    async (req, res) => {
      // Fresh every time: the server's own cache is what keeps stores unhammered.
      res.set("Cache-Control", "no-store");
      const id = String(req.params.id || "");
      if (!ID.test(id)) return res.status(400).json({ error: "Invalid product" });
      if (!lookup.productRecord(id)) return res.status(404).json({ error: "Product not found" });
      const value = await stock.get(id).catch(() => null);
      res.json(value ? { id, live: true, ...value } : { id, live: false });
    });
  return stock;
}
