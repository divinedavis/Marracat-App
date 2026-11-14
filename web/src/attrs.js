// Shopper filters read from what a brand says about a product
// (catalog/attributes.py; owner, 2026-10-10). A product carries
// attrs: { hair: [...], skin: [...], free: [...], skintype: [...], ingredient: [...],
// form: [...], pack: [...], spf: [...], scent: [...], fabric: "..." },
// only the keys that apply. These are the values a filter may ask for.
// Each group shows only in its own department (owner, 2026-11-04: "only have
// filters that reflect skincare in the skincare category and the ones for hair
// in the hair category"). `valueDepartments` narrows single values further.
export const ATTR_FILTERS = {
  // Owner, 2026-11-08: "for clothes do some brands have a women and men
  // filter? if so lets use it ... do it for web/mobile" (catalog/gender.py).
  // Unisex products carry both. Shown wherever products carry it, not only on
  // one department's page: a search for "pants" spans several departments.
  gender: {
    label: "Gender",
    departments: ["clothing", "shoes"],
    anyDepartment: true,
    values: { women: "Women", men: "Men" },
  },
  hair: {
    label: "Hair type",
    departments: ["hair"],
    values: {
      "4c": "For 4C hair", "4b": "For 4B hair", "4a": "For 4A hair", "3c": "For 3C hair",
      coils: "Coily hair", curls: "Curly hair", locs: "Locs", waves: "Waves", straight: "Straight or relaxed",
    },
  },
  skin: {
    label: "Skin concern",
    departments: ["skincare"],
    values: {
      acne: "Acne & breakouts", dark_spots: "Dark spots", aging: "Fine lines & wrinkles", dryness: "Dryness",
      dullness: "Dullness", oily: "Oiliness", pores: "Pores", redness: "Redness", sensitive: "Sensitivity",
      eczema: "Eczema", texture: "Uneven texture", firmness: "Loss of firmness", dark_circles: "Dark circles & puffiness",
    },
  },
  skintype: {
    label: "Skin type",
    departments: ["skincare"],
    values: {
      normal: "Normal", dry: "Dry", oily: "Oily", combination: "Combination", sensitive: "Sensitive",
      mature: "Mature", all: "All skin types",
    },
  },
  ingredient: {
    label: "Key ingredient",
    departments: ["skincare"],
    values: {
      vitamin_c: "Vitamin C", hyaluronic: "Hyaluronic acid", niacinamide: "Niacinamide", retinoid: "Retinol & retinoids",
      bakuchiol: "Bakuchiol", salicylic: "Salicylic acid (BHA)", aha: "AHAs (glycolic, lactic)", peptides: "Peptides",
      ceramides: "Ceramides", squalane: "Squalane", shea: "Shea butter", collagen: "Collagen", centella: "Centella (cica)",
      azelaic: "Azelaic acid", tranexamic: "Tranexamic acid", kojic: "Kojic acid", sulfur: "Sulfur",
      benzoyl: "Benzoyl peroxide", turmeric: "Turmeric",
    },
  },
  free: {
    label: "Ingredient preferences",
    departments: ["hair", "skincare"],
    values: {
      fragrance: "Fragrance-free", sulfate: "Sulfate-free", paraben: "Paraben-free", silicone: "Silicone-free",
      alcohol: "Alcohol-free", oil: "Oil-free", noncomedogenic: "Non-comedogenic", vegan: "Vegan",
      cruelty_free: "Cruelty-free",
    },
    valueDepartments: { oil: ["skincare"], noncomedogenic: ["skincare"] },
  },
  form: {
    label: "Formulation",
    departments: ["skincare"],
    values: {
      serum: "Serum", cream: "Cream", lotion: "Lotion", oil: "Oil", balm: "Balm", butter: "Butter", gel: "Gel",
      foam: "Foam", mist: "Mist & spray", toner: "Toner", mask: "Mask", scrub: "Scrub", bar: "Bar", stick: "Stick",
      wipes: "Wipes & pads", powder: "Powder",
    },
  },
  spf: {
    label: "Sun protection",
    departments: ["skincare"],
    values: { high: "SPF over 30", low: "SPF 30 and under" },
  },
  pack: {
    label: "Minis & sets",
    departments: ["skincare"],
    values: { mini: "Mini & travel", value: "Value size", set: "Gift set", refill: "Refill" },
  },
};
export const ATTR_FIELDS = Object.keys(ATTR_FILTERS);

/// The department a set of products is in, or null when they span several.
export function departmentOf(category, products) {
  if (category) return category;
  let only = null;
  for (const p of products || []) {
    if (only && p.category !== only) return null;
    only = p.category;
  }
  return only;
}

/// Whether a filter value belongs in a department.
export function attrApplies(field, value, department) {
  const spec = ATTR_FILTERS[field];
  if (spec?.anyDepartment) return Object.hasOwn(spec.values, value);
  if (!spec || !department || !spec.departments.includes(department)) return false;
  const only = spec.valueDepartments?.[value];
  return !only || only.includes(department);
}

/// { hair, skin, free, … } from a query (URLSearchParams or a plain object),
/// each an allow-listed value or "".
export function attrOptions(query) {
  const get = (k) => (typeof query?.get === "function" ? query.get(k) : query?.[k]);
  const out = {};
  for (const f of ATTR_FIELDS) {
    const v = get(f);
    out[f] = typeof v === "string" && Object.hasOwn(ATTR_FILTERS[f].values, v) ? v : "";
  }
  return out;
}

/// The rows AttributeFilters would draw; empty means it draws nothing.
export function attributeRows({ category, products, active }) {
  const present = {};
  for (const p of products || []) {
    for (const f of ATTR_FIELDS) for (const v of p.attrs?.[f] || []) (present[f] ||= new Set()).add(v);
  }
  // Skincare filters on skincare, hair filters on hair (owner, 2026-11-04):
  // a department page, or a search whose results are all one department.
  const department = departmentOf(category, products);
  return ATTR_FIELDS.map((f) => {
    const spec = ATTR_FILTERS[f];
    const values = Object.keys(spec.values).filter((v) => active[f] === v || (attrApplies(f, v, department) && present[f]?.has(v)));
    return { f, spec, values };
  }).filter((r) => r.values.length);
}
