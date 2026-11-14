// Omit ownership marketing from the website while preserving the shared catalog.
const ownershipMention = /\bindependent/i;
const sentences = new Intl.Segmenter("en", { granularity: "sentence" });
export function websiteCopy(value) {
  if (typeof value !== "string" || !ownershipMention.test(value)) return value;
  return value
    .split("\n")
    .map((line) =>
      [...sentences.segment(line)]
        .filter((part) => !ownershipMention.test(part.segment))
        .map((part) => part.segment)
        .join("")
        .trim(),
    )
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
export function websiteLabel(value) {
  if (typeof value !== "string") return value;
  return value
    .replace(/\bindependent\b/gi, "")
    .replace(/\s{2,}/g, " ")
    .replace(/^\s*[:—–-]\s*|\s*[:—–-]\s*$/g, "")
    .trim();
}
export function websiteProduct(product) {
  // Nearly every product needs no change, and a copy of each of ~194k held
  // the server near its heap limit while loading: a 2026-11-11 data release
  // ran out of heap on start-up. A product the omission leaves as it was is
  // passed through as the same object (never mutated).
  if (!changes(product)) return product;
  return {
    ...product,
    title: websiteLabel(product.title),
    description: websiteCopy(product.description),
    product_type: websiteLabel(product.product_type),
    tags: (product.tags || []).filter((tag) => !ownershipMention.test(tag)),
    variants: product.variants.map((variant) => ({
      ...variant,
      title: websiteLabel(variant.title),
    })),
  };
}
// A product named only by the omitted wording (the book "Independent", Plant
// and People, 2026-11-11) has no title left to show, so the website leaves it
// out; the app's catalog keeps it.
export function websiteListed(product) {
  return typeof product.title === "string" && product.title.trim().length > 0;
}
// Whether websiteProduct would change anything in this product.
function changes(product) {
  if (websiteLabel(product.title) !== product.title) return true;
  if (websiteLabel(product.product_type) !== product.product_type) return true;
  if (typeof product.description === "string" && ownershipMention.test(product.description)) return true;
  if ((product.tags || []).some((tag) => ownershipMention.test(tag))) return true;
  return (product.variants || []).some((v) => websiteLabel(v.title) !== v.title);
}
export function websiteBrand(brand) {
  const taglines = {
    "before-i-wake": "Pajama sets and sleepwear",
    "mcbride-sisters": "Wine from the McBride Sisters",
  };
  return {
    ...brand,
    tagline: taglines[brand.id] || websiteCopy(brand.tagline),
  };
}
