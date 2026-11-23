// Extra wordings for searches that used to fail (catalog/search_gaps.py writes
// this weekly; only Jev-confirmed, spot-checked phrases). A copy is served at
// marracat.com/search-synonyms.json for the iOS app to load later.
import SEARCH_SYNONYMS from "./search-synonyms.json" with { type: "json" };
import { COLOR_WORD, productColors } from "./colors.js";
import {
  BRAND_LEAD_BONUS, OFF_DEPARTMENT_PENALTY, alternates, alternatives, audienceFit, interests, offDepartments, prefersGuess, saysOwnership, dropOwnership, fold, leadsWithBrand, namesBrand, onlyFiller, respell, singular, splitAudience,
  squash, termMatchers, tokens, vocabulary,
} from "./search-words.js";

export const money = (value, currency = "USD") =>
  new Intl.NumberFormat("en-US", { style: "currency", currency }).format(
    value || 0,
  );
// Sex toys and their gear (the catalog files them all under Sexual Wellness,
// catalog/department_rules.py file_adult) stay in search, their department
// and their brand's page, but off the home page's shared rows (owner,
// 2026-11-16), as the app's Home does (Product.keptOffHome).
// The products not already in one of `rows` (each a list of products), so
// one product page never shows a product in two rows.
export function unseenIn(products, rows) {
  const shown = new Set(rows.flat().map((p) => p.id));
  return products.filter((p) => !shown.has(p.id));
}

// The product's own brand first, other brands only after (owner, 2026-11-17).
export function brandFirst(products, brand) {
  return [...products.filter((p) => p.brand === brand), ...products.filter((p) => p.brand !== brand)];
}

export const keptOffHome = (p) => (p?.subs || []).includes("sexual-wellness");

export function cartTotals(lines) {
  const totals = new Map();
  for (const line of lines) {
    const currency = line.product?.currency || "USD";
    totals.set(currency, (totals.get(currency) || 0) + (line.variant?.price || 0) * line.quantity);
  }
  return [...totals].sort(([a], [b]) => a.localeCompare(b)).map(([currency, amount]) => money(amount, currency)).join(" + ") || money(0);
}
export function safeURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.href : "";
  } catch {
    return "";
  }
}
export function imageURL(value, width = 500) {
  const safe = safeURL(value);
  if (!safe) return "/mark.svg";
  const url = new URL(safe);
  if (url.hostname.endsWith("shopify.com") || url.pathname.includes("/cdn/")) {
    url.searchParams.set("width", width);
    url.searchParams.set("format", "webp");
  }
  return url.href;
}
/// The query, then the synonyms listed for its whole phrase (case and spacing
/// ignored). Phrase-level only, so "durag" expands but "durag satin" doesn't.
export function expandQuery(q, synonyms = SEARCH_SYNONYMS.synonyms) {
  const phrase = String(q || "").toLowerCase().replace(/\s+/g, " ").trim();
  const extra = (phrase && synonyms && Object.hasOwn(synonyms, phrase) && Array.isArray(synonyms[phrase]))
    ? synonyms[phrase].filter((s) => typeof s === "string" && s.trim()).slice(0, 8)
    : [];
  return [q, ...extra];
}

// Dollars per unit before a catalog's brands carry `usd_rate` (catalog/fx.py);
// the app keeps the same table in FX.fallback.
const USD_PER_UNIT = { GBP: 1.321, EUR: 1.119, SEK: 0.1, ZAR: 0.06006, CAD: 0.7032, NGN: 0.000751,
  KES: 0.007716, GHS: 0.08584, XOF: 0.001704, RWF: 0.000677, BWP: 0.07168 };

/** The price in dollars: the brand's own rate, else the fallback table. */
export function usdPrice(p, rate) {
  const currency = p.currency || "USD";
  return currency === "USD" ? p.price : p.price * (rate || USD_PER_UNIT[currency] || 1);
}

// --- Search, as the app runs it (CatalogStore.runSearch) -------------------
// Owner, 2026-10-31: "make sure both search works the same, meaning the way
// someone types in the search and the results show on mobile should be the
// same on the website". A product matches when every word is in its title,
// brand, department or type and tags (a word of 3+ letters may only start
// one; a colour word beside others may be its colour), and it scores as the
// app scores it. Featured results then mix brands as the app does.

let categoryNames = new Map();
/** The department names search reads ("hair" finds Hair Care), from the
 * catalog the server and the page both load, so the two match. */
export function setSearchCategories(categories) {
  categoryNames = new Map((categories || []).map((c) => [c.id, fold(c.name)]));
}

/** A product's searchable text: its title, then its type and tags, folded as
 * the query is (CatalogStore.SearchText). */
export const searchParts = (p) => ({
  title: fold(p.title),
  rest: fold(`${p.product_type || ""} ${(p.tags || []).join(" ")}`),
});

const singularPhrase = (phrase) => phrase.split(" ").map(singular).join(" ");

/** The query and its listed synonyms, each split as the app splits a search. */
function compileQuery(q, synonyms) {
  return expandQuery(q, synonyms)
    .map((wording) => {
      const { words: said, audience } = splitAudience(tokens(wording));
      const words = dropOwnership(said);
      // A colour word also finds a product in that colour, only beside other
      // words, which pick the candidates; alone it reads as text.
      const colors = new Map(words.length > 1 ? words.filter((w) => COLOR_WORD.has(w)).map((w) => [w, COLOR_WORD.get(w)]) : []);
      const terms = words.map((t) => {
        const s = singular(t);
        // Other words for it (alternates): "keyring" finds a keychain, and
        // beside other words "fruit" finds a cherry.
        const others = alternates(s, words.length > 1);
        const alts = others.map((a) => termMatchers(a).term);
        // `keys`: every string this term can match by (searchCandidates).
        return { word: t, long: s.length >= 3, alts, keys: [s, ...others], ...termMatchers(s) };
      });
      // The phrase is what was typed, "independent" and all.
      // Singular words, so "bag charms" says the phrase "Bag Charm" does.
      return { words, terms, audience, colors, phrase: said.length > 1 ? termMatchers(said.map(singular).join(" ")).term : null };
    })
    .filter((w) => w.terms.length);
}

/** One wording's score for a product, as CatalogStore.runSearch scores it; -1 when it doesn't match. */
function scoreWording(p, w, parts, brandName, categoryName) {
  let score = 0;
  for (const t of w.terms) {
    if (t.term(parts.title)) score += 4;
    else if (t.term(brandName)) score += 3;
    else if (t.term(categoryName)) score += 2;
    else if (t.term(parts.rest)) score += 1;
    // A word the search only starts ("butter" in "Buttercream", or one still
    // being typed). One or two letters carry no signal as a prefix: the "d"
    // of "vitamin d" starts "Dark" too.
    else if (t.long && (t.starts(parts.title) || t.starts(brandName) || t.starts(categoryName) || t.starts(parts.rest))) score += 1;
    else if (t.alts.some((a) => a(parts.title))) score += 3;
    else if (t.alts.some((a) => a(parts.rest))) score += 1;
    else if (w.colors.has(t.word) && productColors(p).has(w.colors.get(t.word))) score += 2;
    else return -1;
  }
  const fit = audienceFit(`${parts.title} ${parts.rest}`, w.audience);
  if (fit < 0) return -1;
  // "vitamin d" is one thing: a title that says the whole phrase outranks
  // anything that merely holds the words apart.
  if (w.phrase && w.phrase(parts.title)) score += 10;
  return score + fit * 2 + (p.available ? 1 : 0);
}

/** The scoring function for a query: product (and its searchParts) -> score,
 * -1 for no match. Null when the query has no words at all. */
export function searchScorer(q, brands, synonyms = SEARCH_SYNONYMS.synonyms) {
  const wordings = compileQuery(q, synonyms);
  if (!wordings.length) return null;
  const brandNames = new Map(brands.map((b) => [b.id, fold(b.name)]));
  const scorer = (p, parts = searchParts(p)) => {
    const brandName = brandNames.get(p.brand) || "", categoryName = categoryNames.get(p.category) || "";
    let best = -1;
    for (const w of wordings) best = Math.max(best, scoreWording(p, w, parts, brandName, categoryName));
    return best;
  };
  // The typed wording's words, for leadWithBrands (the app's `tokens`).
  scorer.words = wordings[0].words;
  scorer.brandNames = brandNames;
  scorer.wordings = wordings;
  return scorer;
}

/** Everything search reads of a product, in one string: the text the
 * vocabulary counts words in and the word index files a product under. */
const wholeText = (p, parts, brandNames, names = categoryNames) =>
  `${parts.title} ${brandNames.get(p.brand) || ""} ${names.get(p.category) || ""} ${parts.rest}`;

// --- The server's word index ------------------------------------------------
// A search used to score every product: 194,568 of them took the server
// 0.6-4 s per uncached search with every other request waiting behind it
// (2026-11-10). Every way a term can match (scoreWording) starts at the start
// of a word, so the products holding a word that starts with the term's first
// run of letters are the only ones worth scoring. The index lists them; the
// scorer then runs on those alone and returns what it always did. The page
// in the browser has no index and scores the whole list as before.

const WORD_BREAK = /[^\p{L}\p{N}]+/u;
const LEADING_WORD = /^[\p{L}\p{N}]+/u;

/** Files products one at a time, in catalog order, and packs the index:
 * add(product, parts) then pack(). The page's catalog worker feeds it as the
 * catalog streams in; the server walks its list with wordIndexBuilder. */
export function wordIndexWriter(brands, names = categoryNames) {
  const brandNames = new Map(brands.map((b) => [b.id, fold(b.name)]));
  // Typed arrays, not a list per word: the droplet has 2 GB, and 65,000
  // growing lists of 2.9 M numbers cost several times what these do.
  const grown = (a) => { const b = new Int32Array(a.length * 2); b.set(a); return b; };
  const ids = new Map(); // word -> its number, in the order first seen
  let counts = new Int32Array(1 << 16); // products per word number
  let filed = new Int32Array(1 << 20); // each product's word numbers, product after product
  let ends = new Int32Array(1 << 16); // where each product's run ends in `filed`
  let count = 0, used = 0;
  return {
    get count() { return count; },
    add(p, parts = searchParts(p)) {
      for (const w of new Set(wholeText(p, parts, brandNames, names).split(WORD_BREAK))) {
        if (!w) continue;
        let id = ids.get(w);
        if (id === undefined) {
          ids.set(w, (id = ids.size));
          if (id === counts.length) counts = grown(counts);
        }
        counts[id]++;
        if (used === filed.length) filed = grown(filed);
        filed[used++] = id;
      }
      if (count + 1 === ends.length) ends = grown(ends);
      ends[++count] = used;
    },
    /** Words in alphabetical order (the vocabulary's order), each with the
     * positions of its products, in catalog order, in one packed list. */
    pack() {
      const words = [...ids.keys()].sort();
      const starts = new Int32Array(words.length + 1), cursor = new Int32Array(words.length);
      let total = 0;
      words.forEach((w, at) => {
        const id = ids.get(w);
        starts[at] = cursor[id] = total;
        total += counts[id];
      });
      starts[words.length] = total;
      // Products are walked in order, so each word's list comes out in order.
      const postings = new Int32Array(total);
      for (let i = 0; i < count; i++) for (let k = ends[i]; k < ends[i + 1]; k++) postings[cursor[filed[k]]++] = i;
      return { words, starts, postings };
    },
  };
}

/** Builds the index a slice at a time, so the server can spread the work
 * between requests: step(count) files the next `count` products and is true
 * once all are in, then index() packs it. */
export function wordIndexBuilder(products, brands, haystack = null) {
  const names = categoryNames, writer = wordIndexWriter(brands, names);
  return {
    step(count = Infinity) {
      const end = Math.min(products.length, writer.count + count);
      while (writer.count < end) {
        const p = products[writer.count];
        writer.add(p, haystack?.get(p) ?? searchParts(p));
      }
      return writer.count >= products.length;
    },
    index() {
      if (writer.count < products.length) throw Error("The search index is not finished");
      return { products, brands, names, ...writer.pack(), vocab: null };
    },
  };
}
export function buildWordIndex(products, brands, haystack = null) {
  const builder = wordIndexBuilder(products, brands, haystack);
  builder.step();
  return builder.index();
}

// The page's own index: built by its catalog worker (src/catalog-worker.js)
// off the main thread and adopted here, so a search in the browser scores a
// few hundred products instead of every one, as the server does. Used
// whenever filterProducts is given exactly the list it was built for.
let pageIndex = null;
/** Adopt a packed index for this list. False (and no index) when it was not
 * built for a list this long: it is positions, and would point at the wrong products. */
export function adoptWordIndex(products, brands, packed) {
  pageIndex = null;
  if (!packed || !Array.isArray(packed.words) || !(packed.starts instanceof Int32Array) || !(packed.postings instanceof Int32Array)) return false;
  if (packed.count !== products.length || packed.starts.length !== packed.words.length + 1) return false;
  pageIndex = { products, brands, names: categoryNames, words: packed.words, starts: packed.starts, postings: packed.postings, vocab: null };
  return true;
}
export const adoptedWordIndex = () => pageIndex;
/** For the typing suggestions, which score the same list row by row: a mark
 * per catalog position (1 = could match), or null to score every row. */
export function pageCandidateMarks(products, brands, wordings) {
  return indexFits(pageIndex, products, brands) ? candidateMarks(pageIndex, wordings) : null;
}

/** Is this index for exactly this list, these brands and today's department names? */
const indexFits = (index, products, brands) =>
  Boolean(index) && index.products === products && index.brands === brands && index.names === categoryNames;

/** vocabulary() from the index: the same words, counts and order. */
function indexVocabulary(index) {
  return (index.vocab ??= new Map(index.words.map((w, i) => [w, index.starts[i + 1] - index.starts[i]])));
}

/** The first word at or after `word` in a sorted list. */
function lowerBound(words, word) {
  let lo = 0, hi = words.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (words[mid] < word) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

/** The products a search could match, in catalog order, or null when the
 * index can't narrow it. Per wording, a product must hold, for each term, a
 * word starting with that term's first run of letters or with one of its
 * alternates'. Left unnarrowed: a term a colour can stand in for (the colour
 * is read off the product, not its words), and one so common that listing
 * its products would cost more than scoring them. */
export function searchCandidates(index, wordings) {
  const hit = candidateMarks(index, wordings);
  if (!hit) return null;
  const { products } = index, out = [];
  for (let i = 0; i < hit.length; i++) if (hit[i]) out.push(products[i]);
  return out;
}
/** The same, as a mark per catalog position (1 = could match), or null. */
export function candidateMarks(index, wordings) {
  const { products, words, starts, postings } = index;
  const n = products.length, hit = new Uint8Array(n), mask = new Uint16Array(n);
  for (const w of wordings) {
    const narrowed = [];
    for (const t of w.terms) {
      if (narrowed.length === 16) break;
      if (w.colors.has(t.word)) continue;
      const spans = [];
      let size = 0;
      for (const key of t.keys) {
        const lead = key.match(LEADING_WORD)?.[0];
        if (!lead) { size = Infinity; break; }
        // "\uffff" is no letter or digit, so it sorts after every word that starts with `lead`.
        const from = starts[lowerBound(words, lead)], to = starts[lowerBound(words, lead + "\uffff")];
        size += to - from;
        spans.push([from, to]);
      }
      if (size <= n / 2) narrowed.push(spans);
    }
    if (!narrowed.length) return null;
    mask.fill(0);
    narrowed.forEach((spans, k) => {
      for (const [from, to] of spans) for (let i = from; i < to; i++) mask[postings[i]] |= 1 << k;
    });
    const all = (1 << narrowed.length) - 1;
    for (let i = 0; i < n; i++) if (mask[i] === all) hit[i] = 1;
  }
  return hit;
}

/// CatalogStore.demoteOffDepartments: OFF_DEPARTMENT_PENALTY off the products
/// of a department the search barely touches. `scores` is changed in place.
export function demoteOffDepartments(scores, words) {
  const counts = new Map();
  for (const p of scores.keys()) counts.set(p.category, (counts.get(p.category) || 0) + 1);
  const off = offDepartments(counts, scores.size, words);
  if (!off.size) return;
  for (const [p, n] of scores) if (off.has(p.category)) scores.set(p, n - OFF_DEPARTMENT_PENALTY);
}

/// CatalogStore.leadWithBrands: BRAND_LEAD_BONUS added to the products of
/// every brand the search names and leads with ("fraiche" puts Fraîche
/// Studios before Crème Fraîche). `scores`: product -> score, changed in place.
/// True when a brand leads.
export function leadWithBrands(scores, words, brandNames) {
  const named = new Map();
  for (const [id, name] of brandNames) {
    const n = namesBrand(words, name);
    if (n.matches) named.set(id, n);
  }
  if (!named.size) return false;
  const own = new Map();
  for (const p of scores.keys()) if (named.has(p.brand)) own.set(p.brand, (own.get(p.brand) || 0) + 1);
  const lead = new Set([...named].filter(([id, n]) => leadsWithBrand(n, own.get(id) || 0, scores.size - (own.get(id) || 0))).map(([id]) => id));
  if (!lead.size) return false;
  for (const [p, n] of scores) if (lead.has(p.brand)) scores.set(p, n + BRAND_LEAD_BONUS);
  return true;
}

const MASK64 = (1n << 64n) - 1n;
const utf8 = new TextEncoder();
/** CatalogStore.hash: 64-bit FNV-1a over the UTF-8 bytes, offset by the seed. */
export function brandHash(s, seed) {
  let h = (1469598103934665603n + BigInt(seed)) & MASK64;
  for (const b of utf8.encode(s)) h = ((h ^ BigInt(b)) * 1099511628211n) & MASK64;
  return h;
}

/** The app's seed for mixing brands: today's day number counted from 1 AD
 * (Calendar.ordinality(of: .day, in: .era); 739920 on 2026-10-31). New York's
 * day on the server and in the browser alike, so the server's first page and
 * the page's own sort agree. */
export function daySeed(now = new Date()) {
  const [y, m, d] = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" })
    .format(now).split("-").map(Number);
  return Math.floor(Date.UTC(y, m - 1, d) / 86400000) + 719163;
}

/** CatalogStore.interleaveBrands: results mixed across brands, so a brand with
 * a deep catalog can't own page after page of one search. The best match
 * always comes first; spreading brands only breaks ties, never puts a weaker
 * match above a stronger one. `ranked` is [product, score] in catalog order. */
export function interleaveBrands(ranked, seed = daySeed(), { fromManyBrands = false } = {}) {
  const brandIds = new Set(ranked.map(([p]) => p.brand));
  // One brand: nothing to spread, but the ranking holds (stable, so equal
  // scores keep catalog order), as in the app. `fromManyBrands`: these are
  // the top of a result that spans brands, so they order as that result does.
  if (brandIds.size <= 1 && !fromManyBrands)
    return ranked.map((r, i) => [r, i]).sort((a, b) => b[0][1] - a[0][1] || a[1] - b[1]).map(([[p]]) => p);
  // Each brand's place in hash order, compared as a plain number: the same
  // order as comparing the 64-bit hashes, without millions of BigInt compares.
  const hashes = new Map([...brandIds].map((b) => [b, brandHash(b, seed)]));
  const rank = new Map([...brandIds].sort((a, b) => (hashes.get(a) < hashes.get(b) ? -1 : 1)).map((b, i) => [b, i]));
  const sorted = [...ranked].sort((a, b) => {
    if (a[1] !== b[1]) return b[1] - a[1];
    const ra = rank.get(a[0].brand), rb = rank.get(b[0].brand);
    if (ra !== rb) return ra - rb;
    return a[0].id < b[0].id ? -1 : a[0].id > b[0].id ? 1 : 0;
  });
  const buckets = new Map();
  for (const item of sorted) {
    let list = buckets.get(item[0].brand);
    if (!list) buckets.set(item[0].brand, (list = []));
    list.push(item);
  }
  const head = new Map([...buckets.keys()].map((b) => [b, 0]));
  const next = (b) => buckets.get(b)[head.get(b)][1];
  // Brands by the score of their next product, then by hash: a heap, so a
  // search across hundreds of brands stays fast.
  const before = (x, y) => (next(x) !== next(y) ? next(x) > next(y) : rank.get(x) < rank.get(y));
  const heap = [];
  const push = (b) => {
    heap.push(b);
    for (let i = heap.length - 1; i > 0; ) {
      const up = (i - 1) >> 1;
      if (!before(heap[i], heap[up])) break;
      [heap[i], heap[up]] = [heap[up], heap[i]];
      i = up;
    }
  };
  const pop = () => {
    const top = heap[0], last = heap.pop();
    if (heap.length) {
      heap[0] = last;
      for (let i = 0; ; ) {
        const l = 2 * i + 1, r = l + 1;
        let m = i;
        if (l < heap.length && before(heap[l], heap[m])) m = l;
        if (r < heap.length && before(heap[r], heap[m])) m = r;
        if (m === i) break;
        [heap[i], heap[m]] = [heap[m], heap[i]];
        i = m;
      }
    }
    return top;
  };
  for (const b of buckets.keys()) push(b);
  const out = [], recent = [];
  while (heap.length) {
    // The best brand overall, and the best one not shown in the last two picks.
    const popped = [];
    let best = null, spread = null;
    while (heap.length) {
      const b = pop();
      popped.push(b);
      best ??= b;
      if (!recent.includes(b)) { spread = b; break; }
    }
    spread ??= best;
    const b = next(best) > next(spread) ? best : spread;
    out.push(buckets.get(b)[head.get(b)][0]);
    head.set(b, head.get(b) + 1);
    for (const x of popped) if (x !== b || head.get(x) < buckets.get(x).length) push(x);
    recent.push(b);
    if (recent.length > 2) recent.shift();
  }
  return out;
}

export function filterProducts(
  products,
  brands,
  {
    q = "",
    category = "",
    aisle = "",
    brand = "",
    type = "",
    sale = false,
    under = false,
    stock = false,
    clean = false,
    metal = false,
    scent = false,
    safer = false,
    food = false,
    baby = false,
    fiber = false,
    fabric = false,
    lab = false,
    pet = false,
    material = false,
    home = false,
    // Shopper filters (src/attrs.js): one allow-listed value each, or "".
    gender = "",
    hair = "",
    hairneed = "",
    skin = "",
    free = "",
    skintype = "",
    ingredient = "",
    form = "",
    pack = "",
    spf = "",
    // A colour family (src/colors.js), or "".
    color = "",
    sort = "featured",
    // The server (server/query.js) passes each product's search text built
    // once, rather than rebuilt for every product on every search.
    haystack = null,
    // The server's word index (wordIndexBuilder): only the products a
    // search could match are scored. Without one, every product is.
    index = null,
    synonyms = SEARCH_SYNONYMS.synonyms,
  },
) {
  // The query plus any confirmed wordings of the whole phrase ("durag" also
  // matches "wave cap"), matched and scored as the app does (searchScorer).
  // "women"/"men" narrow by who a product is marked for instead of being
  // words it must contain. A query of nothing but punctuation matches nothing.
  const searching = String(q || "").trim() !== "";
  const score = searching ? searchScorer(q, brands, synonyms) : null;
  const scores = new Map();
  // The server passes its index; the page's own (adoptWordIndex) is used
  // when this is the list it was built for.
  const narrow = indexFits(index, products, brands) ? index : indexFits(pageIndex, products, brands) ? pageIndex : null;
  const pool = (score && narrow && searchCandidates(narrow, score.wordings)) || products;
  const result = pool.filter(
    (p) =>
      (!category || p.category === category) &&
      (!aisle || (p.subs || []).includes(aisle)) &&
      (!brand || p.brand === brand) &&
      // A product type is an aisle id, "department:leaf" (leaves repeat across departments).
      (!type || (p.category === type.split(":")[0] && (p.subs || []).includes(type.split(":")[1]))) &&
      (!sale || p.compare_at > p.price) &&
      (!under || ((p.currency || "USD") === "USD" && p.price < 25)) &&
      (!stock || p.available) &&
      (!clean || p.clean) &&
      (!metal || Boolean(p.metal)) &&
      (!scent || Boolean(p.scent)) &&
      (!safer || Boolean(p.safer)) &&
      (!food || Boolean(p.food)) &&
      (!baby || Boolean(p.baby)) &&
      (!fiber || Boolean(p.fiber)) &&
      (!fabric || Boolean(p.fabric)) &&
      (!lab || Boolean(p.lab)) &&
      (!pet || Boolean(p.pet)) &&
      (!material || Boolean(p.material)) &&
      (!home || Boolean(p.home)) &&
      (!gender || Boolean(p.attrs?.gender?.includes(gender))) &&
      (!hair || Boolean(p.attrs?.hair?.includes(hair))) &&
      (!hairneed || Boolean(p.attrs?.hairneed?.includes(hairneed))) &&
      (!skin || Boolean(p.attrs?.skin?.includes(skin))) &&
      (!free || Boolean(p.attrs?.free?.includes(free))) &&
      (!skintype || Boolean(p.attrs?.skintype?.includes(skintype))) &&
      (!ingredient || Boolean(p.attrs?.ingredient?.includes(ingredient))) &&
      (!form || Boolean(p.attrs?.form?.includes(form))) &&
      (!pack || Boolean(p.attrs?.pack?.includes(pack))) &&
      (!spf || Boolean(p.attrs?.spf?.includes(spf))) &&
      (!color || productColors(p).has(color)) &&
      (!searching ||
        (score !== null &&
          ((n) => {
            if (n < 0) return false;
            scores.set(p, n);
            return true;
          })(score(p, haystack?.get(p) ?? searchParts(p))))),
  );
  // Sold-out items go last whatever the sort.
  const inStock = (a, b) => Number(b.available) - Number(a.available);
  // Prices compare in dollars, so a euro bag sits among dollar bags at its
  // dollar price (grouping by currency put every euro item first, 2026-10-16).
  const rates = new Map(brands.map((b) => [b.id, b.usd_rate]));
  const usd = (p) => usdPrice(p, rates.get(p.brand));
  if (sort === "low") result.sort((a, b) => inStock(a, b) || usd(a) - usd(b));
  else if (sort === "high") result.sort((a, b) => inStock(a, b) || usd(b) - usd(a));
  else if (sort === "new")
    result.sort((a, b) =>
      inStock(a, b) || String(b.published_at || "").localeCompare(String(a.published_at || "")),
    );
  else if (searching) {
    // A search: the app's order, best match first with brands mixed, then
    // sold-out items last.
    // A named brand leads; otherwise a department the search barely touches
    // goes below the rest, so a felting kit is no bag charm (offDepartments).
    if (score && !leadWithBrands(scores, score.words, score.brandNames)) demoteOffDepartments(scores, score.words.length);
    const ranked = interleaveBrands(result.map((p) => [p, scores.get(p)]));
    return [...ranked.filter((p) => p.available), ...ranked.filter((p) => !p.available)];
  } else
    result.sort(
      (a, b) =>
        Number(b.available) - Number(a.available) ||
        (a.best_rank ?? 999) - (b.best_rank ?? 999),
    );
  return result;
}
/// When a search finds nothing, as the app's relaxedSearch: a brand's name run
/// together ("fearofgod") is that brand; then the same words spelled as
/// products spell them ("musthavejoy" -> "must have joy", "hodie" -> "hoodie");
/// then drop words no product uses ("xyzzy t shirts") until something matches,
/// each round keeping the shorter query with the most hits and dropping the
/// earlier word on a tie, and never down to words that only name a business
/// ("xennial co" is not "co"). Returns { q, result } or null when the full
/// query matches or nothing does.
export function relaxedSearch(products, brands, options) {
  // "independent" is no word to keep while dropping others (dropOwnership).
  let words = dropOwnership(tokens(options.q));
  if (!words.length || filterProducts(products, brands, options).length) return null;
  // The word split below can't make "of", which is under three letters.
  const squashed = squash(options.q);
  if (squashed.length >= 4) {
    const brand = brands.find((b) => squash(b.name) === squashed);
    if (brand) {
      const result = filterProducts(products, brands, { ...options, q: brand.name });
      if (result.length) return { q: brand.name, result };
    }
  }
  // The words products use, from the same text search reads.
  const vocab = searchVocabulary(products, brands, options);
  const fixed = respell(options.q, vocab);
  if (fixed) {
    const result = filterProducts(products, brands, { ...options, q: fixed });
    if (result.length) return { q: fixed, result };
    words = dropOwnership(tokens(fixed));
  }
  if (words.length < 2) return null;
  while (words.length > 1) {
    let best = null;
    for (let i = 0; i < words.length; i++) {
      const shorter = words.filter((_, j) => j !== i);
      if (onlyFiller(shorter)) continue;
      const result = filterProducts(products, brands, { ...options, q: shorter.join(" ") });
      if (!best || result.length > best.result.length) best = { words: shorter, result };
    }
    if (!best) return null;
    if (best.result.length) return { q: best.words.join(" "), result: best.result };
    words = best.words;
  }
  return null;
}
/// The words products use (relaxedSearch's vocabulary), for alternatives().
function searchVocabulary(products, brands, options) {
  if (indexFits(options.index, products, brands)) return indexVocabulary(options.index);
  if (indexFits(pageIndex, products, brands)) return indexVocabulary(pageIndex);
  const brandNames = new Map(brands.map((b) => [b.id, fold(b.name)]));
  return vocabulary(products, (p) => wholeText(p, options.haystack?.get(p) ?? searchParts(p), brandNames));
}

/// CatalogStore.alternatives: what a search that found nothing, or only a
/// guess, probably meant (owner, 2026-11-03: suggestions, not "no matches"),
/// each finding products under the same filters.
export function searchAlternatives(products, brands, options, excluding = null) {
  return alternatives(options.q, brands.map((b) => b.name), () => searchVocabulary(products, brands, options),
    (q) => filterProducts(products, brands, { ...options, q }).length, excluding);
}

/// The search as the results page shows it: the exact match, else the
/// relaxed one, else the best guess shown in its place. `showing` is the
/// query the results are for when that isn't what was typed; `guesses` the
/// other "Did you mean" searches. As SearchResultsView in the app.
export function searchWithGuesses(products, brands, options, { relax = true } = {}) {
  const exact = filterProducts(products, brands, options);
  if (exact.length || !String(options.q || "").trim() || !relax) return { result: exact, showing: null, guessed: false, guesses: [] };
  const relaxed = relaxedSearch(products, brands, options);
  let guesses = searchAlternatives(products, brands, options, relaxed ? relaxed.q : null);
  // A brand spelled closer to what was typed beats a shortened search.
  const brandGuess = guesses.length && brands.some((b) => b.name === guesses[0]) ? guesses[0] : null;
  const preferGuess = !!(brandGuess && relaxed && prefersGuess(options.q, brandGuess, relaxed.q));
  const guessed = !relaxed || preferGuess ? guesses[0] ?? null : null;
  if (preferGuess) guesses = [relaxed.q, ...guesses];
  guesses = guesses.filter((g) => g !== guessed).slice(0, 3);
  if (guessed) return { result: filterProducts(products, brands, { ...options, q: guessed }), showing: guessed, guessed: true, guesses };
  if (relaxed) return { result: relaxed.result, showing: relaxed.q, guessed: false, guesses };
  return { result: [], showing: null, guessed: false, guesses: [] };
}

/// CatalogStore.personalPicks: "Picked for you" above a short search (owner,
/// 2026-11-03: someone who has been looking at charms and searches "fruit"
/// sees a charm or two). Up to two products matching the search together
/// with something the shopper has been looking at (interests), from the
/// departments that interest is shopped in, not already among the search's
/// first two. Null for a search of three or more words, one saying "black
/// owned" or one that is a brand's whole name. `viewed` is product ids,
/// newest first; `aisleName(product)` its first aisle's name.
export function personalPicks(products, brands, q, recentSearches, viewed, aisleName, byId) {
  const said = tokens(q);
  const words = dropOwnership(splitAudience(said).words);
  if (words.length < 1 || words.length > 2 || saysOwnership(said)) return null;
  if (brands.some((b) => namesBrand(words, b.name).full)) return null;
  // Each viewed product's first aisle: its name for the phrase, and which
  // aisles go by that name, where its picks must come from.
  const aisleIDs = new Map();
  const aisles = [];
  for (const id of viewed.slice(0, 20)) {
    const p = byId.get(id), name = p && p.subs?.length ? aisleName(p) : null;
    if (!name) continue;
    if (!aisleIDs.has(name)) aisleIDs.set(name, new Set());
    aisleIDs.get(name).add(`${p.category}:${p.subs[0]}`);
    aisles.push(name);
  }
  const wanted = interests(q, recentSearches, aisles);
  if (!wanted.length) return null;
  const top = new Set(filterProducts(products, brands, { q }).slice(0, 2).map((p) => p.id));
  for (const interest of wanted) {
    const sample = filterProducts(products, brands, { q: interest.phrase }).slice(0, 200);
    if (!sample.length) continue;
    const byDepartment = new Map();
    for (const p of sample) byDepartment.set(p.category, (byDepartment.get(p.category) || 0) + 1);
    const departments = new Set([...byDepartment].filter(([, n]) => n * 5 >= sample.length).map(([c]) => c));
    // A viewed aisle ("Keychains & Charms") picks from that aisle only: its
    // name's words also fit charm earrings.
    const inAisle = interest.searched ? null : aisleIDs.get(interest.phrase);
    const picks = filterProducts(products, brands, { q: `${q} ${interest.phrase}` })
      .filter((p) => p.available && departments.has(p.category) && !top.has(p.id)
        && (!inAisle || (p.subs || []).some((leaf) => inAisle.has(`${p.category}:${leaf}`))))
      .slice(0, 2);
    if (picks.length) return { phrase: interest.phrase, searched: interest.searched, products: picks };
  }
  return null;
}
/// Whether a brand's products go in the Marracat cart, as the app decides it
/// (Brand.usesMarracatCart). A Wix store (owner, 2026-11-11: Deseta, the
/// test brand) has no cart link to build, and a WooCommerce store without a
/// verified hand-off (Ten To One) neither: the shopper buys on the brand's
/// own product page ("Shop at …").
export function usesMarracatCart(brand) {
  if (!brand?.shopify) return false;
  if (brand.platform === "wix") return false;
  if (brand.platform === "woocommerce") return brand.checkout === "link" || brand.checkout === "add";
  return true;
}
export function checkoutURL(brand, lines) {
  // A store whose cart link goes nowhere (Telfar) checks out through the review page.
  if (!usesMarracatCart(brand) || !lines.length || brand.checkout === "ucp") return null;
  // Big Cartel: our page posts each item to the brand's cart (server/bigcartel.js).
  if (brand.platform === "bigcartel") {
    if (lines.some((l) => !l.product?.available || !l.variant?.available || !(l.quantity >= 1 && l.quantity <= 99))) return null;
    const items = lines.map((l) => `${l.product.id}:${l.variant.id}:${l.quantity}`).join(",");
    return `/go/bigcartel?brand=${encodeURIComponent(brand.id)}&items=${encodeURIComponent(items)}`;
  }
  // Swell: our server builds the cart and redirects to its checkout (server/swell.js).
  if (brand.platform === "swell") {
    if (lines.some((l) => !l.product?.available || !l.variant?.available || !(l.quantity >= 1 && l.quantity <= 99))) return null;
    const items = lines.map((l) => `${l.product.id}:${l.variant.id}:${l.quantity}`).join(",");
    return `/go/swell?brand=${encodeURIComponent(brand.id)}&items=${encodeURIComponent(items)}`;
  }
  if (
    lines.some(
      (l) =>
        !l.product?.available ||
        !l.variant?.available ||
        !/^\d+$/.test(String(l.variant.id)) ||
        !Number.isInteger(l.quantity) ||
        l.quantity < 1 ||
        l.quantity > 99,
    )
  )
    return null;
  const base = safeURL(`https://${brand.domain}`);
  if (!base) return null;
  const url = new URL(`${new URL(base).origin}/cart/${lines.map((l) => `${l.variant.id}:${l.quantity}`).join(",")}`);
  if (brand.currency) url.searchParams.set("currency", brand.currency);
  return url.href;
}
export function diversify(products, count = 12) {
  const seen = new Set();
  const result = [];
  for (const p of products) {
    if (!seen.has(p.brand) && p.images?.length && p.available) {
      seen.add(p.brand);
      result.push(p);
      if (result.length === count) break;
    }
  }
  return result;
}

/// "color / size" from a product's option_names (catalog/build_catalog.py),
/// or "an option" when the store doesn't name them (owner, 2026-10-16).
export function optionNoun(names) {
  const named = (Array.isArray(names) ? names : []).map((n) => String(n).trim()).filter(Boolean);
  return named.length ? named.join(" / ").toLowerCase() : "an option";
}
