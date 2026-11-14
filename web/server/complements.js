import { rateLimit } from "express-rate-limit";
import { getDomain } from "tldts";
import { readText } from "./store-fetch.js";
import { productRecord, brandRecord } from "./catalog.js";
import { installEventSchema } from "./events.js";
import { installPairingsSchema, MIN_INSTALLS } from "./pairings.js";

// "Goes well with" (owner, 2026-10-10: "Frequently bought together" barely had
// data, 4 pairs from 8 phones). Two sources, merged:
//
// - The brand's own Shopify store: every storefront answers
//   /recommendations/products.json?product_id=…&intent=complementary (what the
//   brand set up as "pairs with") and intent=related (Shopify's own similar
//   picks). Complementary first; related when the brand set none up. Only for
//   brands on Shopify, and only on the domain the catalog has for that brand.
// - Carts: products the same shoppers added together, across brands —
//   pair_installs (the app's carts and orders) and website add_to_cart events
//   from one visitor within two hours. Like pairings.js, a pair needs three
//   different shoppers before it shows, so no one person's habits surface.
//
// A product's Shopify list is cached 24 hours (an empty answer 1 hour), so a
// popular page fetches the brand's store at most once a day.

export const MAX = 12;
export const CACHE_MS = 24 * 3_600_000;
export const EMPTY_CACHE_MS = 3_600_000;
export const FETCH_TIMEOUT_MS = 4000;
export const GLOBAL_CONCURRENCY = 4;
export const MIN_SHOPPERS = MIN_INSTALLS;
const MAX_BODY = 512 * 1024;
const MAX_WAITING = 50;
const SESSION_MS = 2 * 3_600_000;
const ID = /^[a-z0-9][a-z0-9_-]{0,159}$/i;
const DOMAIN = /^(?!-)[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})*\.[a-z]{2,24}$/i;

/// The Shopify product id at the end of a catalog id ("koba-skincare-7334563479734").
export function shopifyID(productID, brandID) {
  const prefix = `${brandID}-`;
  if (!productID.startsWith(prefix)) return null;
  const rest = productID.slice(prefix.length);
  return /^\d{1,20}$/.test(rest) ? rest : null;
}

/// The store host for a catalog brand, or null when it isn't a plain public
/// domain (no IP literals, ports, paths or credentials).
export function storeHost(brand) {
  const host = String(brand?.domain || "").trim().toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
  if (!DOMAIN.test(host) || /^\d+(\.\d+)*$/.test(host)) return null;
  return host;
}

const isShopify = (brand) => brand?.platform === "shopify" || (!brand?.platform && brand?.shopify === true);

/// A small limiter: GLOBAL_CONCURRENCY fetches at once, one per domain; past
/// MAX_WAITING queued fetches, new ones are refused (the page shows carts only).
export function fetchLimiter(global = GLOBAL_CONCURRENCY) {
  let running = 0;
  const queue = [];
  const busy = new Set();
  const pump = () => {
    for (let i = 0; i < queue.length && running < global; i++) {
      const job = queue[i];
      if (busy.has(job.domain)) continue;
      queue.splice(i--, 1);
      running++;
      busy.add(job.domain);
      job.run().then(job.resolve, job.reject).finally(() => { running--; busy.delete(job.domain); pump(); });
    }
  };
  return (domain, run) => {
    if (queue.length >= MAX_WAITING) return Promise.resolve(null);
    return new Promise((resolve, reject) => { queue.push({ domain, run, resolve, reject }); pump(); });
  };
}

/// One GET of the brand's recommendations, following at most one redirect and
/// only within the brand's own registrable domain or myshopify.com.
async function getJSON(url, host, fetchImpl) {
  let target = url;
  for (let hop = 0; hop < 2; hop++) {
    const res = await fetchImpl(target, {
      redirect: "manual", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      headers: { Accept: "application/json", "User-Agent": "Marracat/1.0 (+https://marracat.com)" },
    });
    if (res.status >= 300 && res.status < 400) {
      const next = new URL(res.headers.get("location") || "", target);
      const ok = next.protocol === "https:" && !next.port &&
        (getDomain(next.hostname) === getDomain(host) || next.hostname.endsWith(".myshopify.com"));
      if (!ok || hop) return null;
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

/// The brand's recommended products for this one, as catalog ids, and which
/// intent answered. [] when the store has none or can't be reached.
export async function shopifyRecommendations(product, brand, { fetchImpl = fetch, limiter } = {}) {
  const host = storeHost(brand), id = shopifyID(product.id, brand.id);
  if (!host || !id || !isShopify(brand)) return { ids: [], intent: null };
  for (const intent of ["complementary", "related"]) {
    const url = `https://${host}/recommendations/products.json?product_id=${id}&intent=${intent}&limit=10`;
    const data = await limiter(host, () => getJSON(url, host, fetchImpl)).catch(() => null);
    const list = Array.isArray(data?.products) ? data.products : [];
    const ids = list.map((p) => (Number.isSafeInteger(p?.id) || /^\d{1,20}$/.test(String(p?.id)) ? `${brand.id}-${p.id}` : null))
      .filter(Boolean);
    if (ids.length) return { ids, intent };
  }
  return { ids: [], intent: null };
}

export function installComplementSchema(db) {
  db.exec(`CREATE TABLE IF NOT EXISTS complement_cache (
    product TEXT PRIMARY KEY, ids TEXT NOT NULL, intent TEXT, fetched INTEGER NOT NULL)`);
  installEventSchema(db);
  installPairingsSchema(db);
}

/// Products other shoppers put in the cart with this one: three different
/// shoppers per pair, from the app (pair_installs) and the website.
export function cartComplements(db, productID, min = MIN_SHOPPERS) {
  const counts = new Map();
  for (const r of db.prepare(`SELECT CASE WHEN a=? THEN b ELSE a END other, COUNT(DISTINCT device) n
      FROM pair_installs WHERE a=? OR b=? GROUP BY other`).all(productID, productID, productID))
    counts.set(r.other, (counts.get(r.other) || 0) + r.n);
  for (const r of db.prepare(`SELECT b.product other, COUNT(DISTINCT a.visitor) n FROM site_events a
      JOIN site_events b ON b.visitor=a.visitor AND b.name='add_to_cart' AND b.product<>a.product
        AND ABS(b.ts-a.ts) < ? WHERE a.name='add_to_cart' AND a.product=? GROUP BY b.product`).all(SESSION_MS, productID))
    counts.set(r.other, (counts.get(r.other) || 0) + r.n);
  return [...counts].filter(([, n]) => n >= min).sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : 1)).map(([id]) => id);
}

/// The card fields the website needs to draw a product it may not have yet.
const card = (p) => ({ id: p.id, brand: p.brand, title: p.title, price: p.price, compare_at: p.compare_at ?? null,
  currency: p.currency || "USD", available: !!p.available, images: (p.images || []).slice(0, 1), category: p.category });

export function complementRoutes(app, db, { lookup = productRecord, brandOf = brandRecord, fetchImpl = fetch,
  now = Date.now, limit = 60 } = {}) {
  installComplementSchema(db);
  const limiter = fetchLimiter();
  const inflight = new Map();
  const cached = db.prepare("SELECT ids, intent, fetched FROM complement_cache WHERE product=?");
  const store = db.prepare("INSERT OR REPLACE INTO complement_cache(product, ids, intent, fetched) VALUES(?,?,?,?)");

  async function fromShopify(product, brand) {
    const hit = cached.get(product.id);
    const ids = hit ? JSON.parse(hit.ids) : null;
    if (hit && now() - hit.fetched < (ids.length ? CACHE_MS : EMPTY_CACHE_MS)) return { ids, intent: hit.intent };
    if (!inflight.has(product.id)) {
      inflight.set(product.id, shopifyRecommendations(product, brand, { fetchImpl, limiter })
        .then((r) => { store.run(product.id, JSON.stringify(r.ids), r.intent, now()); return r; })
        .finally(() => inflight.delete(product.id)));
    }
    return inflight.get(product.id);
  }

  app.get("/api/products/:id/complements",
    rateLimit({ windowMs: 60_000, limit, standardHeaders: "draft-8", legacyHeaders: false }),
    async (req, res) => {
      const id = String(req.params.id || "");
      if (!ID.test(id)) return res.status(400).json({ error: "Invalid product" });
      const product = lookup(id);
      if (!product) return res.status(404).json({ error: "Not found" });
      const brand = brandOf(product.brand);
      const shopify = brand && isShopify(brand) ? await fromShopify(product, brand).catch(() => ({ ids: [], intent: null })) : { ids: [], intent: null };
      const carts = cartComplements(db, id);
      const seen = new Set([id]);
      const pick = (ids) => ids.map((x) => (seen.has(x) ? null : (seen.add(x), lookup(x)))).filter((p) => p?.available);
      const fromStore = pick(shopify.ids), fromCarts = pick(carts);
      const products = [...fromStore, ...fromCarts].slice(0, MAX);
      const usedStore = products.some((p) => fromStore.includes(p)), usedCarts = products.some((p) => fromCarts.includes(p));
      const source = usedStore && usedCarts ? "mixed" : usedCarts ? "carts" : brand && isShopify(brand) ? "shopify" : "carts";
      res.set("Cache-Control", "public, max-age=3600");
      res.json({ products: products.map((p) => p.id), source, intent: usedStore ? shopify.intent : null, items: products.map(card) });
    });
}
