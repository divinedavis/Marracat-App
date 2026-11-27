import { rateLimit } from "express-rate-limit";
import { filterProducts, relaxedSearch, wordIndexBuilder, searchParts, searchWithGuesses } from "../src/catalog.js";
import { attrOptions } from "../src/attrs.js";
import { collapseGroups, groupIndex } from "../src/colorways.js";
import { colorCounts, colorOption } from "../src/colors.js";

// The shop, brand, department and search pages used to wait for the whole
// catalog (9.6 MB compressed, 14–45 s on a phone, 2026-10-10) before showing a
// product. /api/query runs the storefront's own filterProducts/relaxedSearch on
// the list the browser would have downloaded and returns one page of it, plus
// the counts the page draws around the grid. The page uses it until the full
// catalog lands, then filters locally exactly as before.

export const PAGE_MAX = 120;
export const MAX_RELAX_WORDS = 6;
export const INDEX_SLICE = 1000;

/// Each product's search text (folded title, then type and tags), as
/// filterProducts reads it, built once per catalog rather than per search.
export function buildHaystack(products) {
  return new Map(products.map((p) => [p, searchParts(p)]));
}
const FLAGS = ["sale", "under", "stock", "clean", "metal", "scent", "safer", "food", "baby", "fiber", "fabric", "lab", "pet", "material", "home"];
const BADGES = ["clean", "metal", "scent", "safer", "food", "baby", "fiber", "fabric", "lab", "pet", "material", "home"];
const SORTS = new Set(["featured", "low", "high", "new"]);
const ID = /^[a-z0-9][a-z0-9_-]{0,79}$/i;
const TYPE = /^[a-z0-9_-]{1,40}:[a-z0-9_-]{1,40}$/i;
// The Country filter: an ISO 3166 two-letter code, as the catalog writes it.
const COUNTRY = /^[A-Z]{2}$/;

/// The query options from a request's query string, or null when one is
/// malformed. Same names the storefront builds in main.jsx.
export function queryOptions(query) {
  const one = (k) => (typeof query[k] === "string" ? query[k] : "");
  const q = one("q").trim().slice(0, 200);
  const category = one("category"), aisle = one("aisle"), brand = one("brand"), type = one("type"), country = one("country");
  for (const [v, re] of [[category, ID], [aisle, ID], [brand, ID], [type, TYPE], [country, COUNTRY]]) if (v && !re.test(v)) return null;
  const sort = one("sort") || "featured";
  if (!SORTS.has(sort)) return null;
  const options = { q, category, aisle, brand, country, type, sort };
  for (const f of FLAGS) options[f] = one(f) === "1";
  // Shopper filters: an unknown value is a bad query, not an empty filter.
  const attrs = attrOptions(query);
  for (const [f, v] of Object.entries(attrs)) if (one(f) && !v) return null;
  // The colour filter (src/colors.js): an unknown colour is a bad query too.
  const color = colorOption(one("color"));
  if (one("color") && !color) return null;
  return { ...options, ...attrs, color };
}

/// How many products each brand and aisle has in a department ("" = the
/// whole shop). The same for every search and filter there, so it is counted
/// once per catalog instead of walking every product on every query.
const countsFor = new WeakMap();
function departmentCounts(products, category) {
  let byDepartment = countsFor.get(products);
  if (!byDepartment) countsFor.set(products, (byDepartment = new Map()));
  let counts = byDepartment.get(category);
  if (!counts) {
    const aisleCounts = {}, brandCounts = {};
    for (const p of products) {
      if (category && p.category !== category) continue;
      brandCounts[p.brand] = (brandCounts[p.brand] || 0) + 1;
      if (category) for (const leaf of p.subs || []) aisleCounts[leaf] = (aisleCounts[leaf] || 0) + 1;
    }
    byDepartment.set(category, (counts = { aisleCounts, brandCounts }));
  }
  return counts;
}

/// Everything a filtered page needs from the whole result, not just the page
/// on screen: the result itself, the relaxed query, and the counts behind the
/// type menu, aisle chips, brand picker, intro line and badge filters.
export function runQuery(products, brands, options, haystack = null, index = null) {
  options = { ...options, haystack, index };
  // Dropping words runs ~n²/2 searches; a 12-word query held the server for
  // 3.5 s. Up to 6 words keeps the storefront's behaviour; longer ones get
  // the exact match only. A miss shows the relaxed search or the best guess
  // at what was meant, and offers the other guesses (searchWithGuesses).
  const words = String(options.q || "").trim().split(/\s+/).filter(Boolean).length;
  const found = searchWithGuesses(products, brands, options, { relax: !!options.q && words <= MAX_RELAX_WORDS });
  const relaxed = found.showing ? { q: found.showing } : null;
  const guessed = found.guessed ? found.showing : null;
  const guesses = found.guesses;
  const shown = found.result;
  // The type and colour menus count the page without their own filter: a
  // relaxed search re-relaxes, a guess re-runs as itself.
  const without = (o) => (guessed ? filterProducts(products, brands, { ...o, q: guessed })
    : relaxed ? relaxedSearch(products, brands, o)?.result : filterProducts(products, brands, o)) || [];
  // As main.jsx: the type menu counts the page without its type filter.
  const typeBase = options.type ? without({ ...options, type: "" }) : shown;
  const typeCounts = {};
  for (const p of typeBase) for (const leaf of p.subs || []) {
    const id = `${p.category}:${leaf}`;
    typeCounts[id] = (typeCounts[id] || 0) + 1;
  }
  // Aisle chips and the brand picker count the whole department, filters aside.
  const { aisleCounts, brandCounts } = departmentCounts(products, options.category);
  const inResult = new Map();
  for (const p of shown) inResult.set(p.brand, (inResult.get(p.brand) || 0) + 1);
  const deptBrands = [...inResult].sort((x, y) => y[1] - x[1]).map(([id]) => id);
  const badges = BADGES.filter((b) => shown.some((p) => p[b]));
  // The colour chips count the page without its own colour, so picking Pink
  // still offers the others.
  const colors = options.color ? colorCounts(without({ ...options, color: "" })) : colorCounts(shown);
  // One card per colourway (catalog/colorways.py), as the storefront shows.
  return { shown: collapseGroups(shown), relaxedQuery: relaxed ? relaxed.q : null, guesses, typeCounts, aisleCounts, brandCounts, deptBrands, badges, colors };
}

/// GET /api/query: one page of a filtered list. `source()` returns
/// { generated_at, products, brands } — the same compact list /api/catalog sends.
export function queryRoutes(app, source) {
  // Each entry holds its result list (references into the catalog), so the
  // cache is bounded by the total held, not by entries: "Shop all" is 146k.
  const cache = new Map();
  const CACHE_REFS = 1_500_000, CACHE_MS = 5 * 60_000;
  let held = 0, haystackFor = null, haystack = null, groups = null, index = null;
  // The word index (src/catalog.js) is built between requests, INDEX_SLICE
  // products at a time: filing all 194,568 at once held the server for as
  // long as the slow searches it replaces. Until it is ready, and whenever a
  // new catalog arrives, searches score the whole list as before.
  const indexFor = (products, brands, haystack) => {
    index = null;
    const builder = wordIndexBuilder(products, brands, haystack);
    const more = () => {
      if (haystackFor !== products) return; // a newer catalog has its own
      if (builder.step(INDEX_SLICE)) index = builder.index();
      else setImmediate(more);
    };
    setImmediate(more);
  };
  const evict = (k) => { held -= cache.get(k).shown.length; cache.delete(k); };
  const prepare = (products, brands) => {
    if (haystackFor === products) return;
    haystack = buildHaystack(products, brands); groups = groupIndex(products); haystackFor = products;
    indexFor(products, brands, haystack);
  };
  // The catalog is loaded when the server starts (a new one arrives by a
  // restart), so the search text and the index are made then, not by the
  // first shopper to search: that search took 8 s after the 2026-11-10 deploy.
  setImmediate(() => {
    const now = source();
    if (now?.products?.length) prepare(now.products, now.brands);
  });
  app.use("/api/query", rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }));
  app.get("/api/query", (req, res) => {
    const options = queryOptions(req.query);
    if (!options) return res.status(400).json({ error: "Bad query" });
    const offset = Math.min(Math.max(parseInt(req.query.offset, 10) || 0, 0), 1_000_000);
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 72, 1), PAGE_MAX);
    const { generated_at, products, brands } = source();
    prepare(products, brands);
    const key = JSON.stringify(options);
    let hit = cache.get(key);
    if (!hit || hit.generated_at !== generated_at || Date.now() - hit.at > CACHE_MS) {
      if (cache.has(key)) evict(key);
      hit = { generated_at, at: Date.now(), ...runQuery(products, brands, options, haystack, index) };
      cache.set(key, hit);
      held += hit.shown.length;
      while (held > CACHE_REFS && cache.size > 1) evict(cache.keys().next().value);
    } else {
      cache.delete(key); // most recently used goes last
      cache.set(key, hit);
    }
    res.set("Cache-Control", "public, max-age=60").json({
      generated_at,
      total: hit.shown.length,
      offset,
      // Cards never read tags (search runs here), the biggest field after the title.
      // A colourway's card carries its members, so its dots work before the
      // full catalog lands.
      products: hit.shown.slice(offset, offset + limit).map(({ tags, ...card }) => {
        const members = card.group && groups.get(card.group);
        return members?.length > 1 ? { ...card, members: members.map(({ tags: _t, ...m }) => m) } : card;
      }),
      relaxedQuery: hit.relaxedQuery,
      guesses: hit.guesses,
      typeCounts: hit.typeCounts,
      aisleCounts: hit.aisleCounts,
      brandCounts: hit.brandCounts,
      badges: hit.badges,
      colors: hit.colors,
    });
  });
}
