import { demoteOffDepartments, interleaveBrands, leadWithBrands, pageCandidateMarks, searchParts, searchScorer } from "./catalog.js";
import { fold, singular, squash, startsWord } from "./search-words.js";

const normalize = (value) =>
  String(value || "")
    .toLocaleLowerCase()
    .trim();
const route = (values) => "/shop?" + new URLSearchParams(values);
const singularPhrase = (phrase) => phrase.split(" ").map(singular).join(" ");
// The app's rule for a department, aisle or kind (SuggestionTerm.matches):
// what's typed starts the name or one of its words ("gloss" finds "lip gloss").
const startsTerm = (name, value, singularValue) => {
  const n = fold(name), k = singularPhrase(n);
  return n.startsWith(value) || n.includes(" " + value) || k.startsWith(singularValue) || k.includes(" " + singularValue);
};

// --- Sentence finishing, as in the app (CatalogStore.completions) ---------
// What the typed words run on to in real product titles: "sea moss" offers
// "sea moss gel", "sea moss gummies". A finish counts when two brands use it,
// or one brand in three titles; fewer is one product's name.
const STOP = new Set(["and", "for", "with", "the", "of", "in", "on", "to", "or", "from", "your", "our", "a", "an", "&"]);
const NOTICES = new Set(["pre-order", "preorder", "sale", "restock", "sold"]);
const MODIFIERS = new Set(("black white blue red pink gold green brown dark deep light silver navy ivory beige mini small medium " +
  "large travel bundle duo trio kids men women unisex limited edition classic original signature luxe premium natural " +
  "organic vegan plus pro max tan purple grey gray orange yellow cream nude olive burgundy maroon teal lavender lilac camel " +
  "khaki charcoal coral rust sage mint rose chocolate espresso mocha taupe blush wine emerald cognac multi xl xxl").split(" "));
const MAX_STARTS = 6000;
// "hoodies"/"hoodie" and "gummies"/"gummy" count as one finish.
export const matchKey = (phrase) =>
  phrase
    .toLowerCase()
    .split(" ")
    .map((w) => {
      if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) w = w.slice(0, -1);
      if (w.length > 3 && w.endsWith("ie")) w = w.slice(0, -2) + "y";
      return w;
    })
    .join(" ");
// Titles cut into word runs at the punctuation that separates a title's parts
// ("Shea Butter Soap - Lavender | 4oz") and at "by", a brand credit.
function titleSegments(p, index, out) {
  const parts = String(p.title || "").toLowerCase().split(/\s[-|–—/:]\s|[,()\[\]|•+;]|\bby\b/);
  for (const part of parts) {
    const words = part.split(/[^\p{L}\p{N}'’&-]+/u).map((w) => w.replace(/^-+|-+$/g, "")).filter(Boolean);
    if (words.length) out.push({ product: index, words });
  }
}
function wordIndex(at) {
  const sorted = [...at.keys()].sort();
  const byKey = new Map();
  for (const w of sorted) {
    const k = matchKey(w);
    if (!byKey.has(k)) byKey.set(k, []);
    byKey.get(k).push(w);
  }
  return { at, sorted, byKey };
}
function wordsFor(index, word, stillTyping) {
  const out = new Set(index.byKey.get(matchKey(word)) || []);
  if (stillTyping) {
    let lo = 0, hi = index.sorted.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (index.sorted[mid] < word) lo = mid + 1; else hi = mid; }
    while (lo < index.sorted.length && index.sorted[lo].startsWith(word)) out.add(index.sorted[lo++]);
  }
  return [...out];
}
export function completions(index, query) {
  const raw = String(query || "").toLowerCase();
  const typed = raw.trim().split(/\s+/).filter(Boolean);
  if (!typed.length) return [];
  const last = typed[typed.length - 1];
  // One letter matches too much of the catalog to finish anything useful.
  if (typed.length === 1 && last.length < 2) return [];
  const head = typed.slice(0, -1);
  const wordDone = /\s$/.test(raw);
  const lastKey = matchKey(last);
  let starts = head.length
    ? index.words.at.get(head[0]) || []
    : wordsFor(index.words, last, !wordDone).flatMap((w) => index.words.at.get(w) || []);
  if (starts.length > MAX_STARTS) starts = starts.slice(0, MAX_STARTS);
  const tallies = new Map();
  for (const [s, i] of starts) {
    const w = index.segments[s].words;
    if (i + typed.length > w.length) continue;
    let ok = true;
    for (let k = 0; k < head.length; k++) if (w[i + k] !== head[k]) { ok = false; break; }
    if (!ok) continue;
    const lastWord = w[i + head.length];
    const exact = lastWord === last || matchKey(lastWord) === lastKey;
    if (!exact && (wordDone || !lastWord.startsWith(last))) continue;
    const product = index.products[index.segments[s].product];
    const phrase = w.slice(i, i + typed.length);
    for (let n = 0; n <= 3; n++) {
      if (n > 0) {
        const next = w[i + typed.length + n - 1];
        if (!next || (next.length < 2 && next !== "&") || /\d/.test(next) || NOTICES.has(next)) break;
        phrase.push(next);
        if (STOP.has(next) || next.length < 3) continue;
      }
      const added = phrase.slice(typed.length);
      if (added.length && added.every((x) => STOP.has(x) || MODIFIERS.has(x))) continue;
      // "… for sensitive" at the window's edge: the word after the stop word
      // is what completes it, and the window can't reach it.
      if (n === 3 && added.length >= 2 && STOP.has(added[added.length - 2])) continue;
      const text = phrase.join(" "), key = matchKey(text);
      let t = tallies.get(key);
      if (!t) tallies.set(key, (t = { forms: new Map(), brands: new Set(), titles: new Set(), image: null, categories: new Map(), exact: false }));
      t.forms.set(text, (t.forms.get(text) || 0) + 1);
      t.brands.add(product.brand);
      t.titles.add(String(product.title).toLowerCase());
      t.categories.set(product.category, (t.categories.get(product.category) || 0) + 1);
      if (!t.image && product.images?.[0]) t.image = product.images[0];
      t.exact = t.exact || exact;
    }
  }
  const kept = [...tallies].filter(([, t]) => t.titles.size >= 2 && (t.brands.size >= 2 || t.titles.size >= 3));
  const score = (t) => 3 * t.brands.size + t.titles.size;
  const bestChild = new Map();
  for (const [key, t] of kept) {
    const space = key.lastIndexOf(" ");
    if (space < 0) continue;
    const parent = key.slice(0, space);
    bestChild.set(parent, Math.max(bestChild.get(parent) || 0, score(t)));
  }
  const result = [];
  for (const [key, t] of kept) {
    // A fragment gives way when a longer finish carries most of its brands.
    if (key.split(" ").length > typed.length && (bestChild.get(key) || 0) >= 0.7 * score(t)) continue;
    const text = [...t.forms].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0][0];
    const category = [...t.categories].sort((a, b) => b[1] - a[1])[0]?.[0];
    result.push({ text, key, image: t.image, category, score: score(t), exact: t.exact });
  }
  return result.sort((a, b) => Number(b.exact) - Number(a.exact) || b.score - a.score || a.text.length - b.text.length);
}

// Building the index walks all ~100k products (300 ms+ on a laptop, more on a
// phone), so it is a generator that yields every few thousand products: the
// page builds it in slices between frames and typing never waits on it.
function* indexSteps(products, brands, categories, subcategories) {
  const brandMap = new Map(brands.map((b) => [b.id, b]));
  const segments = [], at = new Map(), rows = [];
  // Each brand's first product photo, as the app's brand row shows.
  const brandImages = new Map();
  // Brand names as the app compares them: folded, run together, word by word.
  const brandKeys = brandKeysFor(brands);
  const terms = new Map();
  for (let n = 0; n < products.length; n++) {
    if (n % 2000 === 1999) yield;
    const product = products[n];
    // What the search page reads (src/catalog.js), so a suggestion's count
    // and products are the page's own.
    rows.push({ product, parts: searchParts(product) });
    if (!brandImages.has(product.brand) && product.images?.[0]) brandImages.set(product.brand, product.images[0]);
    const first = segments.length;
    titleSegments(product, n, segments);
    for (let s = first; s < segments.length; s++)
      segments[s].words.forEach((w, i) => {
        if (!at.has(w)) at.set(w, []);
        at.get(w).push([s, i]);
      });
    for (const label of new Set(
      [product.product_type, ...(product.tags || [])].filter(Boolean),
    )) {
      const key = normalize(label);
      // Suggest readable catalog terms, not internal merchandising codes.
      if (
        key.length < 3 ||
        key.length > 42 ||
        key.split(/\s+/).length > 5 ||
        !/^[\p{L}][\p{L}\s&'-]+$/u.test(label) ||
        /[a-z][A-Z]/.test(label) ||
        /^[a-z]+(?:-[a-z]+)+$/.test(label)
      )
        continue;
      const existing = terms.get(key);
      if (existing) {
        existing.count++;
        if (!existing.image) existing.image = product.images?.[0];
      } else
        terms.set(key, {
          label: label.trim(),
          key,
          count: 1,
          image: product.images?.[0],
        });
    }
  }
  yield;
  return {
    rows,
    products,
    brands,
    brandMap,
    brandKeys,
    brandImages,
    categories,
    subcategories,
    segments,
    words: wordIndex(at),
    terms: [...terms.values()].filter((t) => t.count >= 2),
  };
}
export function createSearchIndex(products, brands, categories, subcategories = []) {
  const steps = indexSteps(products, brands, categories, subcategories);
  for (;;) {
    const step = steps.next();
    if (step.done) return step.value;
  }
}
// The same index, built a slice at a time. `cancelled()` stops a build whose
// catalog has since been replaced.
export async function buildSearchIndex(products, brands, categories, subcategories = [], cancelled = () => false) {
  const steps = indexSteps(products, brands, categories, subcategories);
  for (;;) {
    const step = steps.next();
    if (step.done) return step.value;
    await new Promise((resolve) => setTimeout(resolve, 0));
    if (cancelled()) return null;
  }
}
export function suggest(index, query) {
  const value = fold(query).trim();
  if (!value) return { items: [], categories: [], count: 0 };
  const singularValue = singularPhrase(value);
  // Everything the search page shows for these words, scored and ordered as
  // it orders them (src/catalog.js, the app's search): the count, the
  // departments and the first product cards all come from it.
  const score = searchScorer(query, index.brands);
  const found = [];
  if (score) {
    // With the page's word index, only the rows that could match are scored
    // (rows are in catalog order, as its positions are): a keystroke used to
    // score every product.
    const could = pageCandidateMarks(index.products, index.brands, score.wordings);
    for (let i = 0; i < index.rows.length; i++) {
      if (could && !could[i]) continue;
      const row = index.rows[i];
      const n = score(row.product, row.parts);
      if (n >= 0) found.push([row.product, n]);
    }
  }
  // A named brand leads, else an off-topic department drops, as on the page.
  if (score && found.length) {
    const scores = new Map(found);
    if (!leadWithBrands(scores, score.words, score.brandNames)) demoteOffDepartments(scores, score.words.length);
    for (const f of found) f[1] = scores.get(f[0]);
  }
  let cards = [];
  if (found.length) {
    // The page lists matches best score first (brands only take turns within
    // a score), sold-out last. So its first four in-stock cards come from
    // matches scoring at least the 4th-best in-stock one, and mixing just
    // those gives the same four without sorting every match on each keystroke.
    const inStock = found.filter(([p]) => p.available).map(([, n]) => n).sort((a, b) => b - a);
    const pool = inStock.length >= 4 ? found.filter(([, n]) => n >= inStock[3]) : found;
    const fromManyBrands = pool !== found && new Set(found.map(([p]) => p.brand)).size > 1;
    const ranked = interleaveBrands(pool, undefined, { fromManyBrands });
    cards = [...ranked.filter((p) => p.available), ...ranked.filter((p) => !p.available)].slice(0, 4);
  } else {
    // Nothing matches the words yet (a word half typed): titles that start
    // with what's typed, as the app's suggestions offer, in stock first.
    const better = (a, b) =>
      Number(b.product.available) - Number(a.product.available) ||
      (a.product.best_rank ?? 999) - (b.product.best_rank ?? 999) ||
      a.at - b.at;
    const top = [];
    index.rows.forEach((row, at) => {
      if (!startsWord(row.parts.title, value)) return;
      const entry = { product: row.product, at };
      if (top.length === 4 && better(entry, top[3]) >= 0) return;
      let i = Math.min(top.length, 3);
      top[i] = entry;
      while (i > 0 && better(top[i], top[i - 1]) < 0) {
        [top[i - 1], top[i]] = [top[i], top[i - 1]];
        i--;
      }
    });
    cards = top.map((t) => t.product);
  }
  const items = [];
  const seen = new Set([matchKey(value)]);
  // The typed words finished from real titles come first, then the aisles
  // they name, then the catalog's own product-type terms.
  for (const c of completions(index, query).slice(0, 4)) {
    if (seen.has(c.key)) continue;
    seen.add(c.key);
    items.push({
      id: "finish:" + c.key,
      kind: "Search",
      label: c.text,
      image: c.image,
      to: route({ q: c.text }),
    });
  }
  items.push(...placeItems(index.categories, index.subcategories, value, singularValue));
  const terms = index.terms
    .filter((t) => t.key !== value && startsTerm(t.key, value, singularValue) && !seen.has(matchKey(t.key)))
    .sort(
      (a, b) =>
        Number(b.key.startsWith(value)) - Number(a.key.startsWith(value)) ||
        b.count - a.count ||
        a.label.localeCompare(b.label),
    )
    .slice(0, 2);
  for (const term of terms)
    items.push({
      id: "term:" + term.key,
      kind: "Search",
      label: term.label,
      image: term.image,
      to: route({ q: term.label }),
    });
  items.push(...brandItems(index.brandKeys, value, (id) => index.brandImages.get(id)));
  // Ten rows at most, and never fewer than three of them products.
  items.splice(7);
  for (const product of cards.slice(0, Math.min(4, 10 - items.length)))
    items.push(productItem(product, index.brandMap));
  const categoryCounts = new Map();
  for (const [product] of found)
    categoryCounts.set(
      product.category,
      (categoryCounts.get(product.category) || 0) + 1,
    );
  const categories = [...categoryCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([id, count]) => ({
      id,
      name: index.categories.find((c) => c.id === id)?.name,
      count,
      to: route({ q: query.trim(), category: id }),
    }))
    .filter((c) => c.name);
  return { items, categories, count: found.length };
}

// --- Pieces suggest() shares with serverSuggestions() ---------------------
/// Brand names as the app compares them: folded, run together, word by word.
export function brandKeysFor(brands) {
  return brands.map((b) => {
    const name = fold(b.name);
    return { brand: b, name, squashed: squash(b.name), words: name.split(/[^\p{L}\p{N}]+/u).filter(Boolean) };
  });
}
/// The first aisle and department the typed words start.
function placeItems(categories, subcategories, value, singularValue) {
  const items = [];
  for (const sub of subcategories.filter((a) => startsTerm(a.name, value, singularValue)).slice(0, 1)) {
    const [category, leaf] = sub.id.split(":");
    items.push({ id: "aisle:" + sub.id, kind: "Aisle", label: sub.name, to: route({ category, aisle: leaf }) });
  }
  for (const category of categories.filter((c) => startsTerm(c.name, value, singularValue)).slice(0, 1))
    items.push({ id: "category:" + category.id, kind: "Department", label: category.name, to: route({ category: category.id }) });
  return items;
}
/// Brands as the app finds them (CatalogStore.suggestions): the name or one
/// of its words starts with what's typed, or the name run together does
/// ("fearofgod" is Fear of God); then, for two or more words, brands whose
/// name holds every word in any order ("aqua water" finds Aqua Equity Water).
function brandItems(brandKeys, value, imageOf) {
  const squashed = squash(value);
  const exact = brandKeys.filter(
    (b) => b.name.startsWith(value) || b.name.includes(" " + value) || (squashed.length >= 3 && b.squashed.startsWith(squashed)),
  );
  const typedWords = value.split(/[^\p{L}\p{N}]+/u).filter((w) => w.length >= 2);
  const exactIds = new Set(exact.map((b) => b.brand.id));
  const wordBrands =
    typedWords.length < 2
      ? []
      : brandKeys.filter((b) => !exactIds.has(b.brand.id) && typedWords.every((w) => b.words.some((n) => n.startsWith(w))));
  return [...exact, ...wordBrands].slice(0, 2).map(({ brand }) => ({
    id: "brand:" + brand.id,
    kind: "Brand",
    label: brand.name,
    image: imageOf(brand.id),
    to: route({ brand: brand.id }),
  }));
}
function productItem(product, brandMap) {
  return {
    id: "product:" + product.id,
    kind: brandMap.get(product.brand)?.name || "Product",
    label: product.title,
    image: product.images?.[0],
    price: product.price,
    currency: product.currency,
    to: "/product?id=" + encodeURIComponent(product.id),
  };
}

// --- While the catalog downloads ------------------------------------------
// The full catalog is ~12 MB and the suggestion index is built from it, so on
// a first visit the panel said "Loading the catalog…" for seconds (owner,
// 2026-11-19). Until the index is ready, the panel offers what needs no
// catalog: the aisles, departments and brands the words start, as suggest()
// does, then the first products from the server's own search
// (/api/query, server/query.js, which the shop page already uses meanwhile).

/// What serverSuggestions() needs: built from the catalog's head alone.
export function liteIndex(brands, categories, subcategories = []) {
  return { brandKeys: brandKeysFor(brands), brandMap: new Map(brands.map((b) => [b.id, b])), categories, subcategories };
}
/// Suggestions for `query` from `lite` and an /api/query answer `found`
/// ({ products, total }, or null while it is on its way).
export function serverSuggestions(lite, query, found) {
  const value = fold(query).trim();
  if (!value) return { items: [], categories: [], count: 0 };
  const items = [
    ...placeItems(lite.categories, lite.subcategories, value, singularPhrase(value)),
    ...brandItems(lite.brandKeys, value, () => undefined),
  ];
  items.splice(7);
  for (const product of (found?.products || []).slice(0, Math.min(4, 10 - items.length)))
    items.push(productItem(product, lite.brandMap));
  // No count: the server's counts colourways as one card, the panel counts
  // every match, so "See all" would change number as the catalog lands.
  return { items, categories: [], count: 0 };
}
/// The /api/query string for a suggestion panel's products.
export const suggestQuery = (query) => "/api/query?" + new URLSearchParams({ q: query.trim(), limit: "4" });
