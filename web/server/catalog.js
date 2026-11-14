import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import Database from "better-sqlite3";
import { brotliCompress, gzip, gunzipSync, constants as zlib } from "node:zlib";
import { promisify } from "node:util";
import { getDomain } from "tldts";
import { websiteProduct, websiteBrand, websiteListed } from "./website-copy.js";
import { setSearchCategories } from "../src/catalog.js";
import { linesText, toLines } from "../src/catalog-format.js";

const brotli = promisify(brotliCompress), gz = promisify(gzip);
// Bumped whenever the list projection changes shape, so a browser holding the
// old one refetches instead of revalidating it.
const PROJECTION = 6;
// The home page's first screen: the hero, one pick per featured brand, one
// photo per department, and the start of the product feed. Kept in step with
// src/main.jsx; tests/catalog.test.js checks the feed matches the full one.
export const HOME_HERO = "silver-riley-4458756145248";
export const HOME_FEATURED = ["silver-riley", "brown-girl-jane", "hanahana-beauty", "the-lip-bar", "pattern-beauty", "estelle-colored-glass"];
export const HOME_FEED = 72;
// Deployed: scripts/split_server_catalog.py's two files. Holding the whole
// catalog in memory crashed the 2 GB droplet at 120,873 products
// (2026-10-02), so only what the grid and search read stays in memory and a
// product page's full record is read from SQLite one row at a time.
const slimFile = new URL("./catalog-slim.json", import.meta.url);
const detailsFile = new URL("./product-details.sqlite", import.meta.url);
const bundled = new URL("./catalog-source.json", import.meta.url);
const local = new URL("../../Marracat/Resources/catalog.json", import.meta.url);
let catalog, productMap, brandNames, list, lines, home, detailRow, brandDomains, querySourceValue;

// Full product records for /api/products/:id; null keeps them in memory
// (development and tests, which load the full catalog).
export function useProductDetails(path) {
  detailRow = null;
  if (!path || !existsSync(path)) return;
  const db = new Database(path, { readonly: true, fileMustExist: true });
  detailRow = db.prepare("SELECT data FROM product_details WHERE id=?");
}
export function setCatalog(next) {
  if (
    !Array.isArray(next.products) ||
    !next.products.length ||
    !Array.isArray(next.brands) ||
    !next.brands.length ||
    !Array.isArray(next.categories)
  )
    throw Error("Invalid catalog");
  if (catalog && next.generated_at < catalog.generated_at) return;
  // Search reads department names ("hair" finds Hair Care), as the app does.
  setSearchCategories(next.categories);
  // A product whose whole title was the omitted wording isn't listed at all.
  const websiteProducts = next.products.map(websiteProduct).filter(websiteListed);
  // The list every page filters and searches. It used to carry every variant
  // of every product, which was over half its 24 MB; the grid only needs the
  // variant of a single-variant product (to add it straight to the cart), and
  // the product page and cart fetch full details from /api/products/:id. The
  // product URL is only used there too.
  const compact = websiteProducts.map((p) => tilePhotos(p, {
    id: p.id,
    brand: p.brand,
    title: p.title,
    category: p.category,
    price: p.price,
    currency: p.currency || "USD",
    compare_at: p.compare_at,
    available: p.available,
    variants: p.variants.length === 1 ? p.variants : undefined,
    product_type: p.product_type,
    tags: p.tags,
    published_at: p.published_at ? String(p.published_at).slice(0, 10) : undefined,
    best_rank: p.best_rank,
    // The Marracat Clean badge, set by catalog/clean_badge.py.
    clean: p.clean ? true : undefined,
    // The Marracat True Metal jewelry badge ("true" | "ethical"), catalog/metal_badge.py.
    metal: p.metal === "true" || p.metal === "ethical" ? p.metal : undefined,
    // Marracat Clear Scent (catalog/scent_badge.py) and Safer Clean (catalog/safer_clean_badge.py).
    scent: p.scent ? true : undefined,
    safer: p.safer ? true : undefined,
    // Marracat Clean Food (catalog/food_badge.py) and Baby Safe (catalog/baby_badge.py).
    food: p.food ? true : undefined,
    baby: p.baby ? true : undefined,
    // Marracat Natural Fiber ("natural" | "organic", catalog/fiber_badge.py) and Safe Fabric (catalog/fabric_badge.py).
    fiber: p.fiber || undefined,
    fabric: p.fabric ? true : undefined,
    // Marracat Lab Verified (catalog/lab_badge.py), Pet Safe (catalog/pet_badge.py),
    // True Material ("true" | "veg", catalog/material_badge.py) and Natural Home
    // ("natural" | "certified", catalog/home_badge.py).
    lab: p.lab ? true : undefined,
    pet: p.pet ? true : undefined,
    material: p.material || undefined,
    home: p.home || undefined,
    // The aisles inside its department (catalog/taxonomy.py), as in the app.
    subs: p.subs?.length ? p.subs : undefined,
    // Shopper filters and colourways (catalog/attributes.py, colorways.py).
    attrs: p.attrs || undefined,
    group: p.group || undefined,
    color: p.group ? p.color : undefined,
    swatch: p.group ? p.swatch : undefined,
  }));
  const subcategories = Array.isArray(next.subcategories) ? next.subcategories : [];
  const brands = next.brands.map(websiteBrand);
  list = packed(JSON.stringify({
    generated_at: next.generated_at,
    brands,
    categories: next.categories,
    subcategories,
    products: compact,
  }), next.generated_at);
  // The same list as lines (src/catalog-format.js), which the page's worker
  // reads a piece at a time. Only its compressed copies are kept: the plain
  // text is another 107 MB the 2 GB droplet has no room to hold twice.
  lines = packed(linesText(toLines({
    generated_at: next.generated_at,
    brands,
    categories: next.categories,
    subcategories,
    products: compact,
  })), next.generated_at + "-lines", { quality: 5, keepBody: false });
  home = packed(JSON.stringify({
    generated_at: next.generated_at,
    partial: true,
    brands,
    categories: next.categories,
    subcategories,
    products: homeProducts(compact),
    total_available: compact.filter((p) => p.available).length,
  }), next.generated_at + "-home");
  // What /api/query filters (server/query.js): the very list /api/catalog
  // sends, so a page drawn from the server matches the one drawn locally once
  // the full catalog lands. Measured at ~30 MB of heap for 146k products.
  querySourceValue = { generated_at: next.generated_at, products: compact, brands };
  productMap = new Map(websiteProducts.map((p) => [p.id, p]));
  brandNames = new Map(brands.map((b) => [b.id, b.name]));
  brandDomains = new Map();
  for (const b of next.brands) {
    const d = registrable(b.domain);
    if (d && !PLATFORM_DOMAINS.has(d) && !brandDomains.has(d)) brandDomains.set(d, { id: b.id, name: b.name, domain: d });
  }
  // The products live on in productMap; keeping next.products as well held
  // every product twice.
  catalog = { ...next, products: undefined };
}

// The grid's photo is the tile and a banner's the hero (catalog/photo_roles.py):
// indices into the full catalog's images, or, in the deployed slim file, the
// tile already first and the hero as a URL (scripts/split_server_catalog.py).
function tilePhotos(p, card) {
  const images = p.images || [];
  const tile = p.tile_image > 0 && images[p.tile_image] ? images[p.tile_image] : images[0];
  const hero = p.hero || (p.hero_image > 0 ? images[p.hero_image] : undefined);
  return { ...card, images: tile ? [tile] : [], hero: hero || undefined };
}

// One product in full, as its page gets it: the details row when the
// server has them, otherwise the in-memory record.
export function productDetails(id) {
  if (detailRow && productMap?.has(id)) {
    const row = detailRow.get(id);
    if (row) return websiteProduct(JSON.parse(row.data));
  }
  return productMap?.get(id);
}

// A product as its page gets it, including the store URL (restock checks).
export function productRecord(id) {
  return productMap?.get(id);
}
// The catalog brand whose store sits on this domain (or a subdomain of the
// same registrable domain: mail.brand.com is brand.com), or null. The order
// email relay uses it to tell a brand's own, DKIM-signed mail from anyone
// else's (relay.js). Shared platform domains never name a brand.
const PLATFORM_DOMAINS = new Set(["myshopify.com", "shopify.com", "bigcartel.com", "shopifyemail.com"]);
const registrable = (d) => (typeof d === "string" && d ? getDomain(d.toLowerCase()) : null);
export function brandForDomain(domain) {
  const d = registrable(domain);
  return (d && brandDomains?.get(d)) || null;
}

// A brand as the catalog carries it, including its UCP endpoint (for the
// checkout builder), or undefined.
export function brandRecord(id) {
  return catalog?.brands?.find((b) => b.id === id);
}

// True once a catalog has loaded, so a page can tell "no such item" from "not ready yet".
export function catalogLoaded() {
  return !!productMap;
}

// What a shared product link's preview shows: its photo, name and brand.
export function shareCard(id) {
  const product = productMap?.get(id);
  if (!product) return null;
  return {
    id: product.id,
    title: product.title,
    brand: brandNames.get(product.brand) || "",
    brandID: product.brand,
    image: product.images?.[0] || null,
    price: typeof product.price === "number" ? product.price : null,
    currency: product.currency || "USD",
    available: !!product.available,
    category: product.category || "",
  };
}

// A department page, /c/<category>[/<aisle>] (owner, 2026-10-09: SEO): its
// name, the brands that sell the most in it and a few of its best sellers.
export function categoryCard(id, aisle = "") {
  const cat = catalog?.categories?.find((c) => c.id === id);
  if (!cat) return null;
  const sub = aisle ? catalog.subcategories?.find((s) => s.id === `${id}:${aisle}`) : null;
  if (aisle && !sub) return null;
  const items = [];
  const brandCount = new Map();
  for (const p of productMap?.values() || []) {
    if (p.category !== id || !p.available || (aisle && !(p.subs || []).includes(aisle))) continue;
    items.push(p);
    brandCount.set(p.brand, (brandCount.get(p.brand) || 0) + 1);
  }
  items.sort((a, b) => (a.best_rank ?? 999) - (b.best_rank ?? 999));
  const brands = [...brandCount].sort((a, b) => b[1] - a[1]).slice(0, 12)
    .map(([b]) => ({ id: b, name: brandNames.get(b) || b }));
  return {
    id, aisle, name: sub ? sub.name : cat.name, department: cat.name,
    count: items.length, brandCount: brandCount.size, brands,
    products: items.slice(0, 12).map((p) => ({ id: p.id, title: p.title, image: p.images?.[0] || null })),
    image: items.find((p) => p.images?.length)?.images?.[0] || null,
  };
}

// Everything the sitemap lists (server/seo.js): brands and departments with
// something for sale, and every product in stock.
export function sitemapEntries() {
  const products = [], brands = new Set(), cats = new Set(), aisles = new Set();
  for (const p of productMap?.values() || []) {
    if (!p.available) continue;
    products.push(p.id);
    brands.add(p.brand);
    if (p.category) cats.add(p.category);
    for (const s of p.subs || []) aisles.add(`${p.category}:${s}`);
  }
  const subs = (catalog?.subcategories || []).filter((s) => aisles.has(s.id)).map((s) => s.id);
  return { generated: catalog?.generated_at || "", products, brands: [...brands], categories: [...cats], aisles: subs };
}

export function querySource() {
  return querySourceValue;
}

// Every product as listed (slim: id, brand, title, price, compare_at, available).
export function allProducts() {
  return productMap ? [...productMap.values()] : [];
}

// A shared brand link's preview: its name, tagline and a photo.
export function brandCard(id) {
  const b = catalog?.brands?.find((x) => x.id === id);
  if (!b) return null;
  const first = websiteBrandProduct(id);
  const products = [];
  for (const p of productMap?.values() || []) {
    if (p.brand !== id || !p.available) continue;
    products.push(p);
  }
  products.sort((x, y) => (x.best_rank ?? 999) - (y.best_rank ?? 999));
  return { id: b.id, title: b.name, tagline: b.tagline || "", domain: b.domain || "", image: first?.images?.[0] || b.image || null,
    count: products.length, products: products.slice(0, 12).map((p) => ({ id: p.id, title: p.title })) };
}
function websiteBrandProduct(id) {
  for (const p of productMap?.values() || []) if (p.brand === id && p.available && p.images?.length) return p;
  return null;
}

// Everything the home page's first screen draws, in the order it draws it.
export function homeProducts(compact) {
  const available = compact
    .map((p, i) => [p, i])
    .filter(([p]) => p.available)
    // The storefront's "featured" order: best-sellers first, ties in catalog order.
    .sort(([a, i], [b, j]) => (a.best_rank ?? 999) - (b.best_rank ?? 999) || i - j)
    .map(([p]) => p);
  const pick = new Map();
  const add = (p) => p && pick.set(p.id, p);
  add(compact.find((p) => p.id === HOME_HERO));
  for (const brand of HOME_FEATURED) {
    // The home page asks both ways: a brand's first product with a photo for
    // the picks row, and its first product at all for the two banner images.
    add(available.find((p) => p.brand === brand && p.images?.length));
    add(available.find((p) => p.brand === brand));
  }
  for (const category of new Set(compact.map((p) => p.category)))
    add(available.find((p) => p.category === category && p.images?.length));
  available.slice(0, HOME_FEED).forEach(add);
  // Catalog order, not pick order: the storefront's sort is stable, so ties
  // then fall out exactly as they will in the full list, and the feed doesn't
  // reshuffle under the shopper when the rest of the catalog arrives.
  const position = new Map(compact.map((p, i) => [p.id, i]));
  return [...pick.values()].sort((a, b) => position.get(a.id) - position.get(b.id));
}

// A JSON body compressed once when the catalog changes, rather than by nginx
// on every request at its cheapest setting. Until the compressed copies are
// ready the plain body goes out and nginx compresses it as before.
function packed(body, version, { quality = 9, keepBody = true } = {}) {
  // Bytes only: keeping the JSON string as well held the list twice (a
  // non-ASCII title makes V8 store all of it at two bytes a character).
  const buffer = Buffer.from(body);
  const entry = { body: buffer, etag: `"${version}-p${PROJECTION}"`, br: null, gzip: null };
  const br = brotli(buffer, { params: { [zlib.BROTLI_PARAM_QUALITY]: quality, [zlib.BROTLI_PARAM_SIZE_HINT]: buffer.length } })
    .then((b) => { entry.br = b; }).catch(() => {});
  const gzip = gz(buffer, { level: quality >= 9 ? 9 : 6 }).then((b) => { entry.gzip = b; }).catch(() => {});
  // Once both copies exist the plain one can go; a client that takes neither
  // (none that runs the page does) has the gzip copy unpacked for it.
  if (!keepBody) Promise.all([br, gzip]).then(() => { if (entry.br && entry.gzip) entry.body = null; });
  return entry;
}

function sendPacked(req, res, entry) {
  res.set({ "Cache-Control": "public, max-age=300", ETag: entry.etag, Vary: "Accept-Encoding" });
  // nginx marks an ETag weak (W/) when it compresses the body itself.
  if ((req.get("If-None-Match") || "").replace(/^W\//, "") === entry.etag) return res.sendStatus(304);
  const accepts = req.get("Accept-Encoding") || "";
  res.type("json");
  if (entry.br && /\bbr\b/.test(accepts)) return res.set("Content-Encoding", "br").send(entry.br);
  if (entry.gzip && /\bgzip\b/.test(accepts)) return res.set("Content-Encoding", "gzip").send(entry.gzip);
  return res.send(entry.body ?? gunzipSync(entry.gzip));
}
if (existsSync(slimFile) && existsSync(detailsFile)) {
  useProductDetails(fileURLToPath(detailsFile));
  setCatalog(JSON.parse(readFileSync(slimFile, "utf8")));
} else {
  setCatalog(JSON.parse(readFileSync(existsSync(bundled) ? bundled : local, "utf8")));
}
export function catalogRoutes(app) {
  // ?lines=1: the same list a piece per line, for the page's worker.
  app.get("/api/catalog", (req, res) => sendPacked(req, res, req.query.lines === "1" ? lines : list));
  app.get("/api/home", (req, res) => sendPacked(req, res, home));
  app.get("/api/products/:id", (req, res) => {
    const product = productDetails(req.params.id);
    if (!product) return res.status(404).json({ error: "Product not found" });
    res.set("Cache-Control", "public, max-age=300").json(product);
  });
  // Until 2026-10-02 production also re-read catalog-v2.json from the
  // marracat-catalog GitHub repo every 15 minutes. Publishing moved to the
  // droplet, so that copy froze on 2026-09-23: every run downloaded and parsed
  // 78 MB only to discard it as older. Each deploy carries the catalog.
}
