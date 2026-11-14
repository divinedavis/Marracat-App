// A brand's live catalog, for phones that refresh it faster than the 3-hour
// publish (owner, 2026-10-20). Each phone decides from its own shopper's
// looks: a product viewed 4+ times in a week, or a brand page visited that
// often, makes its brand refresh every 5 min (last look under a day ago),
// 15 min (1-3 days) or 30 min (3-7 days). The phone asks here; it never
// calls a store itself.
//
// Shopify only (/products.json, keyless, in the store's own currency like
// the catalog), and only the domain our catalog has for the brand. One answer
// per brand is shared by every phone for CACHE_MS, so a brand many shoppers
// watch is still asked at most once in that time; a failure is remembered for
// FAIL_CACHE_MS. Fetches go through the shared per-store limiter, and the
// route is rate limited per address. Products come back in the catalog's
// shape; the phone keeps its own department and badges for ones it knows.
import express from "express";
import { rateLimit } from "express-rate-limit";
import { brandRecord, productRecord } from "./catalog.js";
import { fetchLimiter } from "./complements.js";
import { readText } from "./store-fetch.js";

export const CACHE_MS = 5 * 60_000;
export const FAIL_CACHE_MS = 2 * 60_000;
export const FETCH_TIMEOUT_MS = 10_000;
export const PAGE_SIZE = 250;
export const MAX_PAGES = 8;          // 2,000 products: every store a phone would watch
const MAX_BODY = 8_000_000;
const MAX_IMAGES = 6;
const ID = /^[a-z0-9][a-z0-9_-]{0,79}$/i;
const HOST = /^(?!-)[a-z0-9-]+(\.[a-z0-9-]+)+$/i;
// The catalog's SKIP (catalog/build_catalog.py): listings that aren't products.
const SKIP = /gift ?card|e-?gift|gift certificate|sponsorship|shipping protection|\broute\b|package protection|insurance|donation|tip\b|custom order|deposit|test product|do not purchase|promo_item|bundle builder|build your own|paint ?& ?sip|\bworkshop\b|\bticket\b|\brsvp\b|\bclass\b|\bwholesale\b|mystery box|\bdisplay unit\b/i;

const money = (v) => {
  const f = Number(v);
  return Number.isFinite(f) && f > 0 ? Math.round(f * 100) / 100 : null;
};
const unescape = (s) => String(s).replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">");

/// The store to ask for a brand, or null: Shopify brands with a plain domain.
export function freshTarget(brand) {
  if (!brand || brand.platform && brand.platform !== "shopify" || brand.shopify === false) return null;
  const domain = String(brand.domain || "").toLowerCase();
  return HOST.test(domain) ? { domain, currency: brand.currency || "USD" } : null;
}

/// One Shopify product in the catalog's shape (as build_catalog.normalize
/// makes it, less what only the full build knows: department, aisles, badges).
export function freshProduct(brand, p) {
  const title = unescape((p?.title || "").trim());
  const ptype = String(p?.product_type || "").trim();
  if (!title || SKIP.test(title) || SKIP.test(ptype)) return null;
  const images = (p.images || []).map((i) => i?.src).filter((s) => typeof s === "string" && s.startsWith("https://")).slice(0, MAX_IMAGES);
  if (!images.length) return null;
  const variants = [];
  for (const v of p.variants || []) {
    const price = money(v?.price);
    const id = Number(v?.id);
    if (price == null || !Number.isSafeInteger(id)) continue;
    variants.push({ id, title: unescape(v.title || "Default Title").slice(0, 200), price,
      compare_at: money(v.compare_at_price), available: v.available !== false });
  }
  if (!variants.length || !Number.isSafeInteger(Number(p.id))) return null;
  const buyable = variants.filter((v) => v.available);
  const pick = (buyable.length ? buyable : variants).reduce((a, b) => (b.price < a.price ? b : a));
  return {
    id: `${brand.id}-${p.id}`, brand: brand.id, title, category: "", subs: [],
    product_type: ptype || null, currency: brand.currency || "USD",
    price: pick.price, compare_at: pick.compare_at && pick.compare_at > pick.price ? pick.compare_at : null,
    images, url: `https://${brand.domain}/products/${encodeURIComponent(p.handle || "")}`,
    available: variants.some((v) => v.available), variants, tags: [],
    published_at: p.published_at || p.created_at || null,
  };
}

/// What a store fetch found that the published catalog doesn't show yet
/// (owner, 2026-10-21: is the 5-minute tier worth its requests?): products
/// whose price or stock moved, and products the catalog doesn't have.
export function freshDiff(products, lookup = productRecord) {
  const d = { price: 0, stock: 0, added: 0 };
  for (const p of products || []) {
    const known = lookup(p.id);
    if (!known) { d.added++; continue; }
    if (Number(known.price) !== p.price || (known.compare_at ?? null) !== p.compare_at) d.price++;
    if (!!known.available !== p.available) d.stock++;
  }
  return d;
}

/// A day's counts per brand in brand_fresh_stats: phones' asks, store
/// fetches (the rest were answered from the shared cache), failed fetches,
/// fetches that found a change, and the changes found. A change still
/// unpublished is counted again by each later fetch until the next publish.
export function freshStats(db, { now = Date.now } = {}) {
  db.exec(`CREATE TABLE IF NOT EXISTS brand_fresh_stats (
    day TEXT NOT NULL, brand TEXT NOT NULL, asks INTEGER NOT NULL DEFAULT 0, fetches INTEGER NOT NULL DEFAULT 0,
    failures INTEGER NOT NULL DEFAULT 0, changed INTEGER NOT NULL DEFAULT 0, price INTEGER NOT NULL DEFAULT 0,
    stock INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, brand))`);
  const bump = db.prepare(`INSERT INTO brand_fresh_stats (day, brand, asks, fetches, failures, changed, price, stock, added)
    VALUES (@day, @brand, @asks, @fetches, @failures, @changed, @price, @stock, @added)
    ON CONFLICT (day, brand) DO UPDATE SET asks = asks + @asks, fetches = fetches + @fetches,
      failures = failures + @failures, changed = changed + @changed, price = price + @price,
      stock = stock + @stock, added = added + @added`);
  const zero = { asks: 0, fetches: 0, failures: 0, changed: 0, price: 0, stock: 0, added: 0 };
  return {
    record(brand, counts) {
      try { bump.run({ ...zero, ...counts, brand, day: new Date(now()).toISOString().slice(0, 10) }); }
      catch { /* counting never breaks a refresh */ }
    },
  };
}

/// The report's numbers since `since` (YYYY-MM-DD): totals and the busiest brands.
export function freshReport(db, since, top = 10) {
  const total = db.prepare(`SELECT COALESCE(SUM(asks),0) asks, COALESCE(SUM(fetches),0) fetches,
    COALESCE(SUM(failures),0) failures, COALESCE(SUM(changed),0) changed, COALESCE(SUM(price),0) price,
    COALESCE(SUM(stock),0) stock, COALESCE(SUM(added),0) added, COUNT(DISTINCT brand) brands
    FROM brand_fresh_stats WHERE day >= ?`).get(since);
  const brands = db.prepare(`SELECT brand, SUM(asks) asks, SUM(fetches) fetches, SUM(changed) changed,
    SUM(price) price, SUM(stock) stock, SUM(added) added FROM brand_fresh_stats WHERE day >= ?
    GROUP BY brand ORDER BY fetches DESC LIMIT ?`).all(since, top);
  return { ...total, by_brand: brands };
}

async function getJSON(url, fetchImpl) {
  const res = await fetchImpl(url, { redirect: "error", signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    headers: { Accept: "application/json", "User-Agent": "Marracat/1.0 (+https://marracat.com)" } });
  if (!res.ok) return null;
  const text = await readText(res, MAX_BODY);
  if (text == null) return null;
  try { return JSON.parse(text); } catch { return null; }
}

export function brandFresh({ lookup = { brandRecord, productRecord }, fetchImpl = fetch, now = Date.now,
  limiter = fetchLimiter(), stats = null } = {}) {
  const cache = new Map();
  const inflight = new Map();
  async function fetchAll(brand, target) {
    const out = [];
    for (let page = 1; page <= MAX_PAGES; page++) {
      const json = await getJSON(`https://${target.domain}/products.json?limit=${PAGE_SIZE}&page=${page}`, fetchImpl);
      if (!json || !Array.isArray(json.products)) return page === 1 ? null : out;
      for (const p of json.products) { const n = freshProduct(brand, p); if (n) out.push(n); }
      if (json.products.length < PAGE_SIZE) break;
    }
    return out;
  }
  async function get(id) {
    if (!ID.test(id)) return null;
    const brand = lookup.brandRecord(id);
    const target = freshTarget(brand);
    if (!target) return null;
    stats?.record(id, { asks: 1 });
    const hit = cache.get(id);
    if (hit && now() - hit.at < (hit.value ? CACHE_MS : FAIL_CACHE_MS)) return hit.value;
    if (!inflight.has(id)) {
      inflight.set(id, limiter(target.domain, () => fetchAll(brand, target))
        .catch(() => null)
        .then((products) => {
          const value = products && { brand: id, checked_at: new Date(now()).toISOString(), products };
          if (stats) {
            const d = products ? freshDiff(products, lookup.productRecord || productRecord) : null;
            stats.record(id, d ? { fetches: 1, changed: d.price + d.stock + d.added ? 1 : 0, ...d } : { fetches: 1, failures: 1 });
          }
          cache.set(id, { at: now(), value });
          return value;
        })
        .finally(() => inflight.delete(id)));
    }
    return inflight.get(id);
  }
  return { get };
}

export function brandFreshRoutes(app, { db = null, fresh = brandFresh({ stats: db && freshStats(db) }), limit = 30 } = {}) {
  const router = express.Router();
  router.use(rateLimit({ windowMs: 60_000, limit, standardHeaders: "draft-8", legacyHeaders: false }));
  router.get("/:id/fresh", async (req, res) => {
    const value = await fresh.get(String(req.params.id || ""));
    if (!value) return res.status(404).json({ live: false });
    res.set("Cache-Control", "public, max-age=60");
    res.json(value);
  });
  app.use("/api/brands", router);
  return fresh;
}
