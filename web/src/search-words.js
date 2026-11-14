// How a search reads its words (owner, 2026-10-15, after a visitor's
// "musthavejoy" found nothing while "must have joy" found 259, and "pink shirt
// women" found 13 against "pink shirt"'s 87). The app does the same in
// CatalogStore.runSearch.

/// Lowercase, accents off ("Adèle" -> "adele"), apostrophes dropped
/// ("Women's" -> "womens", "McDonald's" -> "mcdonalds"). Applied to the query
/// and to every product's search text alike. Exactly SearchWords.fold in the
/// app (2026-10-31): only a string with an accented Latin letter or a
/// combining mark loses its diacritics, and only those ("™", "½", "ø", "ß"
/// and ligatures stay as they are; "Beard Oil™" still says "oil").
const ACCENTED = /[\u00c0-\u024f\u0300-\u036f]/;
const DIACRITICS = /[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]/g;
const QUOTES = /['`\u2018\u2019]/g;
export function fold(s) {
  let t = String(s || "").toLowerCase();
  if (ACCENTED.test(t)) t = t.normalize("NFD").replace(DIACRITICS, "").normalize("NFC");
  return t.replace(QUOTES, "");
}

/// Does `w` start a word in `text`? "dress" finds "Dresses" and "T-Shirt
/// Dress" but not "Hairdressings" or "Address" (a hair oil came first for
/// "pink dress"), and "shirt" no longer finds every "Sweatshirt". The app
/// matches the same way (CatalogStore.startsWord).
export function startsWord(text, w) {
  for (let i = text.indexOf(w); i >= 0; i = text.indexOf(w, i + 1)) {
    if (i === 0 || !/[\p{L}\p{N}]/u.test(text[i - 1])) return true;
  }
  return false;
}

/// A plural matched by its singular: "shirts" -> "shirt", and "dresses",
/// "watches", "boxes" lose the "es" ("dresse" matched no "Dress").
export function singular(w) {
  if (w.length > 4 && /(sses|shes|ches|xes)$/.test(w)) return w.slice(0, -2);
  if (w.length > 3 && w.endsWith("s") && !w.endsWith("ss")) return w.slice(0, -1);
  return w;
}

/// Who a search is for. These words are a preference, not words a product
/// must contain: few titles say "women", so requiring it dropped most
/// women's shirts. Products marked for the other one are left out instead,
/// and ones marked for this one go first.
export const AUDIENCE = {
  women: new Set(["women", "womens", "woman", "ladies", "lady", "female", "her", "hers"]),
  men: new Set(["men", "mens", "man", "male", "gents", "him", "his"]),
};
// Words that mark a product for one audience (SearchWords.womenMarks/menMarks).
const MARKS = {
  women: new Set(["women", "womens", "woman", "womans", "ladies", "lady", "female", "girl", "girls"]),
  men: new Set(["men", "mens", "man", "mans", "male", "gents", "guys", "boy", "boys"]),
};

/// The query's words minus audience words, and the audience they named
/// ("women", "men" or ""). A query of nothing but audience words keeps them.
export function splitAudience(words) {
  let audience = "";
  const rest = [];
  for (const w of words) {
    const a = AUDIENCE.women.has(w) ? "women" : AUDIENCE.men.has(w) ? "men" : "";
    if (a && (!audience || audience === a)) audience = a;
    else rest.push(w);
  }
  return rest.length ? { words: rest, audience } : { words, audience: "" };
}

/// "independent" says who a brand is, and every brand on Marracat is: a
/// shopper's "independent bag charms" wants every bag charm, not the black
/// ones (owner, 2026-11-01: it found nothing, then only black-coloured
/// charms). "independent", "independent", "independent" and "independent" leave
/// the query when other words remain; alone they stay. A title that says the
/// whole query still goes first ("independent business tote" leads with the
/// "Independent Business" totes). As SearchWords.dropOwnership in the app.
export function dropOwnership(words) {
  const rest = [];
  for (let i = 0; i < words.length; i++) {
    const n = ownershipSpan(words, i);
    if (n) {
      i += n - 1;
      continue;
    }
    rest.push(words[i]);
  }
  return rest.length ? rest : words;
}

/// How many words at `i` say "independent": 1 for "independent" / "independent",
/// 2 for black|blk followed by owned, own, ownd, owner or owners (owner,
/// 2026-11-08: the notice shows for "independent" with any words before or
/// after, and its near spellings), else 0. As SearchWords.ownershipSpan.
const OWNERSHIP_JOINED = new Set(["independent", "independent"]);
const OWNERSHIP_SECOND = new Set(["owned", "own", "ownd", "owner", "owners"]);
export function ownershipSpan(words, i) {
  if (OWNERSHIP_JOINED.has(words[i])) return 1;
  if ((words[i] === "black" || words[i] === "blk") && OWNERSHIP_SECOND.has(words[i + 1])) return 2;
  return 0;
}

/// Words that name a business rather than a thing ("xennial co"). Dropping
/// the unknown name from a search must not leave only these: "co" alone
/// matched 6,627 products (2026-11-01). As SearchWords.filler in the app.
export const FILLER = new Set(["co", "company", "inc", "llc", "ltd", "the", "shop", "store", "brand"]);
export const onlyFiller = (words) => words.every((w) => FILLER.has(w));

/// -1 marked for the other audience (leave out), 1 marked for this one or
/// unisex, 0 neither. `text` is folded. Whole words, as the app reads them.
export function audienceFit(text, audience) {
  if (!audience) return 0;
  const words = new Set(text.split(/[^\p{L}\p{N}]+/u));
  const mine = MARKS[audience], other = MARKS[audience === "women" ? "men" : "women"];
  for (const w of mine) if (words.has(w)) return 1;
  if (words.has("unisex")) return 1;
  for (const w of other) if (words.has(w)) return -1;
  return 0;
}

// --- Respelling a search that found nothing -------------------------------

const vocabCache = new WeakMap();

/// word -> how many products use it, as the app's SearchWordIndex counts:
/// every word of a product's search text (any language; one count per
/// product), in alphabetical order, which is how a tie between two equally
/// close corrections is settled.
export function vocabulary(products, textOf) {
  let v = vocabCache.get(products);
  if (v) return v;
  const counts = new Map();
  for (const p of products) {
    for (const w of new Set(textOf(p).split(/[^\p{L}\p{N}]+/u))) if (w) counts.set(w, (counts.get(w) || 0) + 1);
  }
  v = new Map([...counts].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)));
  vocabCache.set(products, v);
  return v;
}

/// Damerau-Levenshtein distance, giving up past `max`.
export function distance(a, b, max = 2) {
  if (Math.abs(a.length - b.length) > max) return max + 1;
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    let best = Infinity;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
      best = Math.min(best, d[i][j]);
    }
    if (best > max) return max + 1;
  }
  return d[a.length][b.length];
}

/// "musthavejoy" -> "must have joy": the split into 2 or 3 known words of 3+
/// letters whose rarest word is most used ("bangsi" is not "bang si"). Each
/// word must be on 2+ products, as closestWord asks: "xennial" split into
/// "xen nial" off one product's "nial" (2026-11-01). Null when there is none.
export function splitRunTogether(word, vocab) {
  // Long words are pasted junk, and every split is a lookup (the server runs this).
  if (word.length < 6 || word.length > 30) return null;
  let best = null;
  const consider = (parts) => {
    if (!parts.every((p) => p.length >= 3 && (vocab.get(p) || 0) >= 2)) return;
    const score = Math.min(...parts.map((p) => vocab.get(p)));
    if (!best || parts.length < best.parts.length || (parts.length === best.parts.length && score > best.score)) best = { parts, score };
  };
  for (let i = 3; i <= word.length - 3; i++) {
    consider([word.slice(0, i), word.slice(i)]);
    for (let j = i + 3; j <= word.length - 3; j++) consider([word.slice(0, i), word.slice(i, j), word.slice(j)]);
  }
  return best ? best.parts.join(" ") : null;
}

/// The closest known word to a misspelling: one edit for 4–7 letters, two
/// from 8; the most used wins a tie. Null when nothing is that close.
/// `slack` allows that many more edits (alternatives() guesses wider).
export function closestWord(word, vocab, slack = 0) {
  if (word.length < 4 || word.length > 20 || /\d/.test(word)) return null;
  const max = (word.length >= 8 ? 2 : 1) + slack;
  let best = null;
  for (const [w, n] of vocab) {
    if (n < 2 || w.length < 2 || Math.abs(w.length - word.length) > max || w[0] !== word[0] && w[1] !== word[1]) continue;
    const d = distance(word, w, max);
    if (d <= max && (!best || d < best.d || (d === best.d && n > best.n))) best = { w, d, n };
  }
  return best?.w ?? null;
}

/// The query with every word no product uses split ("musthavejoy") or
/// corrected ("hodie"), or null when nothing changed.
export function respell(q, vocab) {
  const words = tokens(q);
  let changed = false;
  const out = words.map((w) => {
    if (vocab.has(w) || vocab.has(singular(w))) return w;
    const fixed = splitRunTogether(w, vocab) || closestWord(w, vocab);
    if (fixed) changed = true;
    return fixed || w;
  });
  return changed ? out.join(" ") : null;
}

// --- The app's matching rules (CatalogStore / SearchWords.swift) ----------
// Owner, 2026-10-31: "make sure both search works the same". These mirror
// SearchWords.tokens/squash and CatalogStore.matchesWord/matchesTerm, so a
// query matches the same products, in the same order, on both.

const LETTER_OR_DIGIT = /[\p{L}\p{N}]/u;
const isWordChar = (c) => c !== undefined && LETTER_OR_DIGIT.test(c);

/// The query's words: folded, split at anything that isn't a letter or digit
/// ("t-shirt" -> "t", "shirt"), as SearchWords.tokens does.
export function tokens(q) {
  return fold(q).split(/[^\p{L}\p{N}]+/u).filter(Boolean);
}

/// Letters and digits only: "Fear of God" -> "fearofgod".
export function squash(s) {
  return fold(s).replace(/[^\p{L}\p{N}]+/gu, "");
}

/// `needle` as a whole word of `text`; a trailing "s"/"es" is the same word.
export function matchesWord(text, needle) {
  if (!needle) return false;
  for (let i = text.indexOf(needle); i >= 0; i = text.indexOf(needle, i + 1)) {
    if (i > 0 && isWordChar(text[i - 1])) continue;
    let end = i + needle.length;
    for (let k = 0; k < 2 && end < text.length && (text[end] === "s" || text[end] === "e"); k++) end++;
    if (end === text.length || !isWordChar(text[end])) return true;
  }
  return false;
}

/// A whole word, or a phrase ending in a short letter run followed by digits:
/// "vitamin d" finds "Vitamin D3", but "d" alone never starts "Dark".
export function matchesTerm(text, term) {
  if (!term || !text.includes(term)) return false;
  if (matchesWord(text, term)) return true;
  const last = term.split(" ").pop();
  if (!(last.length <= 2 && /^\p{L}+$/u.test(last))) return false;
  for (let i = text.indexOf(term); i >= 0; i = text.indexOf(term, i + 1)) {
    if (i > 0 && isWordChar(text[i - 1])) continue;
    let end = i + term.length;
    while (end < text.length && /\p{N}/u.test(text[end])) end++;
    if (end > i + term.length && (end === text.length || !isWordChar(text[end]))) return true;
  }
  return false;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
/// matchesTerm and startsWord for one search term, compiled once per search:
/// the same answers, at native speed, when one keystroke checks every title.
export function termMatchers(term) {
  const e = escapeRe(term);
  const word = new RegExp(`(?<![\\p{L}\\p{N}])${e}[se]{0,2}(?![\\p{L}\\p{N}])`, "u");
  const last = term.split(" ").pop();
  const digits = last.length <= 2 && /^\p{L}+$/u.test(last) ? new RegExp(`(?<![\\p{L}\\p{N}])${e}\\p{N}+(?![\\p{L}\\p{N}])`, "u") : null;
  const start = new RegExp(`(?<![\\p{L}\\p{N}])${e}`, "u");
  return {
    term: (text) => text.includes(term) && (word.test(text) || (digits !== null && digits.test(text))),
    starts: (text) => text.includes(term) && start.test(text),
  };
}

// --- Brand lead, other words, the ownership notice, guesses, picks --------
// Owner, 2026-11-03, after a returning shopper's searches: lead with a brand
// when its name is searched, add synonyms, show a charm or two to someone who
// has been looking at charms, suggest what a search meant instead of "no
// results", and say that everything here is independent when that is
// searched. As SearchWords.swift in the app, line for line.

/// Does a search name this brand? Its words, business words aside, are the
/// first words of the brand's name: "fraiche" names Fraîche Studios, "xennial
/// co" The Xennial Co. `words` is how many words named it; `full` when they
/// are the whole name.
export function namesBrand(words, brandName) {
  const q = words.filter((w) => !FILLER.has(w));
  const b = tokens(brandName).filter((w) => !FILLER.has(w));
  if (!q.length || q.length > b.length || q.join("").length < 3) return { matches: false, full: false, words: 0 };
  for (let i = 0; i < q.length; i++) if (q[i] !== b[i] && singular(q[i]) !== singular(b[i])) return { matches: false, full: false, words: 0 };
  return { matches: true, full: q.length === b.length, words: q.length };
}

/// A search that names a brand puts that brand first, unless its words are an
/// everyday word other brands' products use more than the brand itself does
/// ("black" names twenty brands, "okra" O'kra's 3 products and 58 others). A
/// brand's whole name of two or more words always leads.
export function leadsWithBrand(named, own, others) {
  return named.matches && own > 0 && ((named.full && named.words >= 2) || others <= own);
}

/// What leading adds to a brand's products' scores: more than any match
/// elsewhere can score, so the brand comes first.
export const BRAND_LEAD_BONUS = 20;

/// Departments a search barely touches (owner, 2026-11-03: craft kits and tea
/// outranked real bag charms and purses). Only for a focused search: 10+
/// matches with one department holding 2 in 5 of them, and no brand leading.
/// Then a department whose products merely mention things (craft kits and
/// supplies, food and tea, book and album titles, cards, stationery, toys) is
/// off topic when it holds under 1 in 20 of a one-word search's matches, or
/// under 1 in 8 of a longer one's ("bag charm fruit"), and its products drop
/// by OFF_DEPARTMENT_PENALTY, below everything on topic. A broad word ("pink")
/// moves nothing, and a search naming that thing ("felting kit", "tea") makes
/// it the main department. `counts`: Map of matches per department; `words`:
/// the search's. As SearchWords.offDepartments.
export const MENTIONING_DEPARTMENTS = new Set(["crafts", "grocery", "books", "music", "party", "office", "toys"]);
export function offDepartments(counts, total, words) {
  if (total < 10) return new Set();
  const top = Math.max(0, ...counts.values());
  if (top * 5 < total * 2) return new Set();
  const share = words > 1 ? 8 : 20;
  return new Set([...counts].filter(([c, n]) => MENTIONING_DEPARTMENTS.has(c) && n * share < total).map(([c]) => c));
}
export const OFF_DEPARTMENT_PENALTY = 15;

/// Other words for a search word, keyed by its singular. `always`: the same
/// thing. `beside`: a looser kind, counted only beside other words, as a
/// colour is ("bag charm fruit" finds the cherry charm; "fruit" alone stays
/// fruit). A product matching only another word scores below one using it.
export const ALWAYS_ALTERNATES = {
  keychain: ["key chain", "keyring", "key ring", "key fob"],
  keyring: ["keychain", "key chain", "key ring"],
};
export const BESIDE_ALTERNATES = {
  keychain: ["charm"],
  keyring: ["charm"],
  charm: ["keychain", "keyring", "key chain"],
  fruit: ["strawberry", "strawberries", "cherry", "cherries", "apple", "lemon", "banana", "pineapple",
    "watermelon", "grape", "mango", "kiwi", "berry", "berries", "pear", "plum", "fig", "citrus"],
};
export function alternates(singularWord, beside) {
  return [...(Object.hasOwn(ALWAYS_ALTERNATES, singularWord) ? ALWAYS_ALTERNATES[singularWord] : []),
    ...(beside && Object.hasOwn(BESIDE_ALTERNATES, singularWord) ? BESIDE_ALTERNATES[singularWord] : [])];
}

/// Does the search say "independent" (any spelling dropOwnership takes)? Then
/// the results say that everything on Marracat is (owner, 2026-11-03).
export function saysOwnership(words) {
  return words.some((_, i) => ownershipSpan(words, i) > 0);
}

// Swift's String < (compares Unicode scalars), for ties sorted as the app sorts them.
const before = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/// What a search probably meant, for when it found nothing or only a guess:
/// brands spelled close to it, the query respelled allowing one more edit,
/// then each of its own words that finds something, most results first. Only
/// guesses that find products, never the query itself or `excluding`; up to
/// `limit`. `count` runs a search.
export function alternatives(query, brandNames, vocab, count, excluding = null, limit = 3) {
  const out = [];
  // Compared without business words: "xennial co" is The Xennial Co.
  const keyOf = (t) => squash(tokens(t).filter((w) => !FILLER.has(w)).join(""));
  const seen = new Set([keyOf(query)]);
  if (excluding) seen.add(keyOf(excluding));
  const shownWords = new Set(tokens(excluding || ""));
  const offer = (guess) => {
    const key = keyOf(guess);
    if (out.length >= limit || !key || seen.has(key)) return;
    seen.add(key);
    if (count(guess) > 0) out.push(guess);
  };
  const sq = squash(tokens(query).filter((w) => !FILLER.has(w)).join(""));
  if (sq.length >= 4) {
    const max = sq.length >= 8 ? 2 : 1;
    const close = [];
    for (const name of brandNames) {
      const bs = squash(tokens(name).filter((w) => !FILLER.has(w)).join(""));
      if (!bs) continue;
      const d = bs.startsWith(sq) ? 0 : distance(sq, bs, max);
      if (d <= max) close.push({ name, d });
    }
    close.sort((a, b) => (a.d !== b.d ? a.d - b.d : before(a.name, b.name)));
    for (const c of close.slice(0, 2)) offer(c.name);
  }
  const words = tokens(query);
  const all = vocab();
  const known = new Set();
  for (const [w, n] of all) if (n >= 2) known.add(w);
  let changed = false;
  const loose = words.map((w) => {
    if (known.has(w) || known.has(singular(w))) return w;
    const fixed = closestWord(w, all, 1);
    if (!fixed) return w;
    changed = true;
    return fixed;
  });
  if (changed) offer(loose.join(" "));
  if (words.length > 1) {
    // Not a word of the search already shown ("bag charm 3d" shows "bag charm").
    const single = words.filter((w) => w.length >= 3 && !FILLER.has(w) && !shownWords.has(w)).map((w) => [w, count(w)]);
    single.sort((a, b) => (a[1] !== b[1] ? b[1] - a[1] : before(a[0], b[0])));
    for (const [w, n] of single) if (n > 0) offer(w);
  }
  return out;
}

/// Show a brand guess instead of the shortened or respelled search when the
/// brand's name is closer to what was typed: "brandon blakwod" is Brandon
/// Blackwood, not "brandon"; "xennail" The Xennial Co, not "nail". Business
/// words aside, by edit distance. As SearchWords.prefersGuess.
export function prefersGuess(query, guess, relaxed) {
  const keyOf = (t) => squash(tokens(t).filter((w) => !FILLER.has(w)).join(""));
  const q = keyOf(query);
  return distance(q, keyOf(guess), 64) < distance(q, keyOf(relaxed), 64);
}

/// What a shopper has been looking at, for "Picked for you" on a short search:
/// their recent searches, newest first, then the aisles of what they viewed,
/// most viewed first. Phrases sharing a word with the search, or holding only
/// business or ownership words, are skipped. Up to three, each with whether
/// it was a search.
export function interests(query, recentSearches, viewedAisles) {
  const said = new Set(dropOwnership(tokens(query)).map(singular));
  const aisleCount = new Map();
  for (const a of viewedAisles) if (a) aisleCount.set(a, (aisleCount.get(a) || 0) + 1);
  const order = [...aisleCount.keys()];
  const aisles = order.map((a, i) => [a, i]).sort((x, y) => aisleCount.get(y[0]) - aisleCount.get(x[0]) || x[1] - y[1]).map(([a]) => a);
  const out = [], seen = new Set();
  for (const [phrase, searched] of [...recentSearches.slice(0, 5).map((q) => [q, true]), ...aisles.slice(0, 3).map((a) => [a, false])]) {
    const words = dropOwnership(tokens(phrase)).filter((w) => !FILLER.has(w));
    const key = words.map(singular).join(" ");
    if (!words.length || saysOwnership(words) || !words.every((w) => !said.has(singular(w))) || seen.has(key)) continue;
    seen.add(key);
    out.push({ phrase, searched });
    if (out.length === 3) break;
  }
  return out;
}
