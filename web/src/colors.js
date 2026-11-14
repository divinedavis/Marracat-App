// Colour families for the colour filter and for colour words in a search
// (owner, 2026-10-15: a shopper searched "pink top", "pink dress" and "pink
// shirt" for five minutes and only opened pink earrings). The same families
// as the app's Filters sheet (Marracat/Filters.swift, ProductFacets).

export const COLOR_FAMILIES = [
  { id: "black", label: "Black", hex: "#1b1b1b", words: ["black", "jet", "onyx", "noir"] },
  { id: "white", label: "White", hex: "#f7f7f5", words: ["white", "ivory", "cream", "off-white", "ecru"] },
  { id: "grey", label: "Grey", hex: "#8d8f91", words: ["grey", "gray", "charcoal", "slate", "graphite", "ash", "heather"] },
  { id: "blue", label: "Blue", hex: "#2f5fa7", words: ["blue", "navy", "denim", "teal", "turquoise", "indigo", "cobalt", "aqua"] },
  { id: "green", label: "Green", hex: "#3f7d4a", words: ["green", "olive", "sage", "mint", "emerald", "lime", "forest", "khaki"] },
  { id: "red", label: "Red", hex: "#b3261e", words: ["red", "burgundy", "maroon", "wine", "crimson", "scarlet", "rust"] },
  { id: "pink", label: "Pink", hex: "#e9a1b5", words: ["pink", "rose", "blush", "fuchsia", "magenta", "coral"] },
  { id: "purple", label: "Purple", hex: "#6a3f8f", words: ["purple", "lavender", "lilac", "violet", "plum", "mauve"] },
  { id: "orange", label: "Orange", hex: "#e2702a", words: ["orange", "peach", "apricot", "terracotta", "copper"] },
  { id: "yellow", label: "Yellow", hex: "#efc93a", words: ["yellow", "mustard", "lemon", "butter"] },
  { id: "brown", label: "Brown", hex: "#6b4a32", words: ["brown", "chocolate", "coffee", "mocha", "espresso", "caramel", "tan", "taupe", "camel"] },
  { id: "beige", label: "Beige", hex: "#d9c7a7", words: ["beige", "nude", "sand", "oat", "bone", "natural"] },
  { id: "gold", label: "Gold", hex: "#c9a54a", words: ["gold", "brass", "bronze"] },
  { id: "silver", label: "Silver", hex: "#c4c6c8", words: ["silver", "platinum", "chrome", "steel"] },
  { id: "multi", label: "Multicolor", hex: "", words: ["multi", "multicolor", "multicolour", "rainbow", "assorted"] },
];
export const COLOR_IDS = COLOR_FAMILIES.map((f) => f.id);

/// word -> family id, for every family word and its plural ("blues").
export const COLOR_WORD = new Map();
for (const f of COLOR_FAMILIES) for (const w of f.words) {
  COLOR_WORD.set(w, f.id);
  COLOR_WORD.set(w + "s", f.id);
}

// A product title says a colour only with words that mean nothing else:
// "Shea Butter", "Natural Hair", "Forest Walk" and "Coffee Mug" are not
// colours, but those words are when a brand names a variant ("Butter / M").
const TITLE_WORDS = new Set(["black", "white", "ivory", "cream", "grey", "gray", "charcoal", "blue", "navy", "teal",
  "turquoise", "indigo", "cobalt", "green", "olive", "emerald", "red", "burgundy", "maroon", "crimson", "scarlet",
  "pink", "blush", "fuchsia", "magenta", "purple", "lavender", "lilac", "violet", "mauve", "orange", "yellow",
  "mustard", "brown", "taupe", "camel", "beige", "gold", "silver", "bronze", "multicolor", "rainbow"]);
// "Black TV Moms Sweatshirt", "Black Girl Magic Tee", "Brown Skin Girl": who
// it is for, not what colour it is.
const IDENTITY = /\b(black|brown)[\s-]+(owned|girls?|boys?|wom[ae]n|m[ae]n|moms?|mothers?|dads?|fathers?|tv|history|excellence|love|joy|lives|culture|power|queens?|kings?|magic|business|kids?|family|educators?|teachers?|nurses?|doctors?|art|artists?|beauty|hair|skin|brilliance|pride|is|sugar|people|folks?|mama|papa|sisters?|brothers?|bride|cowboys?|santa|jesus|barbie)\b/g;
// Departments where a "colour" is a shade, a scent or a flavour, or a book's
// title: no colour filter there.
const NO_COLOR = new Set(["books", "music", "grocery", "alcohol", "fragrance", "wellness", "skincare", "household"]);

const cache = new WeakMap();

function addWords(text, out, allowed) {
  // "Rose Gold" is gold, not pink.
  const t = text.replace(/\brose[\s-]+gold\b/g, "gold");
  for (const w of t.split(/[^a-z-]+/)) {
    if (!w) continue;
    for (const part of w.includes("-") && w !== "off-white" ? [w, ...w.split("-")] : [w]) {
      const id = COLOR_WORD.get(part);
      if (id && (!allowed || allowed.has(part) || allowed.has(part.replace(/s$/, "")))) out.add(id);
    }
  }
}

/// The colour families a product comes in: its colourway colour
/// (catalog/colorways.py), its variant names ("Pink / M") and colour words in
/// its title. Remembered per product object.
export function productColors(p) {
  let out = cache.get(p);
  if (out) return out;
  out = new Set();
  if (!NO_COLOR.has(p.category)) {
    if (p.color) addWords(String(p.color).toLowerCase(), out);
    for (const v of p.variants || []) {
      if (!v?.title || v.title === "Default Title") continue;
      for (const part of String(v.title).toLowerCase().split("/")) if (part.trim().length < 24) addWords(part, out);
    }
    for (const part of p.opts || []) if (String(part).length < 24) addWords(String(part).toLowerCase(), out);
    addWords(String(p.title || "").toLowerCase().replace(IDENTITY, " "), out, TITLE_WORDS);
  }
  cache.set(p, out);
  return out;
}

/// family id -> how many of `products` come in it, in family order, only
/// families present.
export function colorCounts(products) {
  const counts = new Map();
  for (const p of products) for (const id of productColors(p)) counts.set(id, (counts.get(id) || 0) + 1);
  return Object.fromEntries(COLOR_IDS.filter((id) => counts.has(id)).map((id) => [id, counts.get(id)]));
}

/// A colour filter value from a query, allow-listed, or "".
export const colorOption = (v) => (typeof v === "string" && COLOR_IDS.includes(v) ? v : "");
