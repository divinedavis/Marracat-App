// A shared product link, marracat.com/p/<id>, is the website's own page, but
// iMessage, WhatsApp and the rest read its <head> for the preview card. Without
// this every product previewed as the generic site card (logo + tagline), so
// the page gets that product's photo, name and brand as Open Graph tags.
const escape = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

// JSON-LD inside a <script> block: escape "<" so no value can close the tag.
const jsonld = (data) =>
  `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, "\\u003c")}</script>`;
const ORIGIN = "https://marracat.com";
const desc = (s, max = 158) => {
  const t = String(s || "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max - 1).trimEnd() + "…" : t;
};

/// Safari's Smart App Banner: "Open" hands this address to the app, which
/// opens /p/<id> as that product (MarracatApp.openProductLink).
export function withAppArgument(html, url) {
  return html.replace(/<meta name="apple-itunes-app" content="app-id=(\d+)[^"]*"\s*\/?>/,
    (_, id) => `<meta name="apple-itunes-app" content="app-id=${id}, app-argument=${escape(url)}"/>`);
}

export function sharePage(html, card) {
  if (!card) return html;
  // Brand on the line under the product name, the way the card reads.
  const title = card.brand ? `${card.title} · ${card.brand}` : card.title;
  const url = `https://marracat.com/p/${encodeURIComponent(card.id)}`;
  const tags = [
    `<title>${escape(title)} | Marracat</title>`,
    `<meta property="og:type" content="product"/>`,
    `<meta property="og:site_name" content="Marracat"/>`,
    `<meta property="og:title" content="${escape(title)}"/>`,
    `<meta property="og:description" content="${escape(card.brand ? `Shop ${card.brand} on Marracat` : "Shop on Marracat")}"/>`,
    `<meta property="og:url" content="${escape(url)}"/>`,
    card.image && /^https:\/\//.test(card.image) ? `<meta property="og:image" content="${escape(card.image)}"/>` : "",
    `<meta name="twitter:card" content="summary_large_image"/>`,
    `<meta name="description" content="${escape(desc(card.brand ? `${card.title} by ${card.brand}. Shop it on Marracat and check out with ${card.brand} directly.` : `${card.title} on Marracat.`))}"/>`,
    // Product structured data (schema.org/Product) for search results.
    jsonld({
      "@context": "https://schema.org", "@type": "Product", name: card.title, url,
      ...(card.image && /^https:\/\//.test(card.image) ? { image: card.image } : {}),
      ...(card.brand ? { brand: { "@type": "Brand", name: card.brand } } : {}),
      ...(typeof card.price === "number" ? { offers: {
        "@type": "Offer", price: card.price.toFixed(2), priceCurrency: card.currency || "USD", url,
        availability: card.available ? "https://schema.org/InStock" : "https://schema.org/OutOfStock",
      } } : {}),
    }),
  ].join("");
  return withAppArgument(html, url)
    .replace(/<title>[^<]*<\/title>/, "")
    .replace(/<meta (property|name)="(og:[^"]+|twitter:card|description)"[^>]*\/>/g, "")
    .replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g, "")
    .replace(/<link rel="canonical"[^>]*>/, `<link rel="canonical" href="${escape(url)}"/>`)
    .replace("</head>", `${tags}</head>`);
}

/// The same for a shared brand link, marracat.com/b/<id>.
export function brandSharePage(html, card) {
  if (!card) return html;
  const url = `https://marracat.com/b/${encodeURIComponent(card.id)}`;
  const tags = [
    `<title>${escape(card.title)} | Marracat</title>`,
    `<meta property="og:type" content="website"/>`,
    `<meta property="og:site_name" content="Marracat"/>`,
    `<meta property="og:title" content="${escape(card.title)} on Marracat"/>`,
    `<meta property="og:description" content="${escape(card.tagline || `Shop ${card.title} on Marracat`)}"/>`,
    `<meta property="og:url" content="${escape(url)}"/>`,
    card.image && /^https:\/\//.test(card.image) ? `<meta property="og:image" content="${escape(card.image)}"/>` : "",
    `<meta name="twitter:card" content="summary_large_image"/>`,
    `<meta name="description" content="${escape(desc(`Shop ${card.title} on Marracat${card.tagline ? `: ${card.tagline}` : ""}. ${card.count ? `${card.count} products, ` : ""}checkout with ${card.title} directly.`))}"/>`,
    jsonld({
      "@context": "https://schema.org", "@type": "CollectionPage", name: `${card.title} on Marracat`, url,
      about: { "@type": "Brand", name: card.title, ...(card.domain ? { url: `https://${card.domain}` } : {}) },
      mainEntity: { "@type": "ItemList", numberOfItems: card.count || 0,
        itemListElement: (card.products || []).map((p, i) => ({ "@type": "ListItem", position: i + 1, name: p.title,
          url: `${ORIGIN}/p/${encodeURIComponent(p.id)}` })) },
    }),
  ].join("");
  // Drop the site's own Open Graph tags so the brand's win.
  return withAppArgument(html, url)
    .replace(/<title>[^<]*<\/title>/, "")
    .replace(/<meta (property|name)="(og:[^"]+|twitter:card|description)"[^>]*\/>/g, "")
    .replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g, "")
    .replace(/<link rel="canonical"[^>]*>/, `<link rel="canonical" href="${escape(url)}"/>`)
    .replace("</head>", `${tags}</head>`);
}

/// A department page, marracat.com/c/<category>[/<aisle>] (owner, 2026-10-09:
/// SEO). Public copy says "independent brands", never "independent"
/// (feedback_marracat_no_independent_wording).
export function categoryTitle(card) {
  return `${card.name} from independent brands`;
}
export function categorySharePage(html, card) {
  if (!card) return html;
  const path = `/c/${encodeURIComponent(card.id)}${card.aisle ? `/${encodeURIComponent(card.aisle)}` : ""}`;
  const url = ORIGIN + path;
  const title = categoryTitle(card);
  const description = desc(`Shop ${card.name.toLowerCase()} from ${card.brandCount} independent ${card.brandCount === 1 ? "brand" : "brands"} on Marracat` +
    (card.brands.length ? `, including ${card.brands.slice(0, 3).map((b) => b.name).join(", ")}` : "") +
    `. ${card.count} ${card.count === 1 ? "product" : "products"}, all in one place.`);
  const tags = [
    `<title>${escape(title)} | Marracat</title>`,
    `<meta name="description" content="${escape(description)}"/>`,
    `<meta property="og:type" content="website"/>`,
    `<meta property="og:site_name" content="Marracat"/>`,
    `<meta property="og:title" content="${escape(title)}"/>`,
    `<meta property="og:description" content="${escape(description)}"/>`,
    `<meta property="og:url" content="${escape(url)}"/>`,
    card.image && /^https:\/\//.test(card.image) ? `<meta property="og:image" content="${escape(card.image)}"/>` : "",
    `<meta name="twitter:card" content="summary_large_image"/>`,
    jsonld({
      "@context": "https://schema.org", "@type": "CollectionPage", name: title, url, description,
      ...(card.aisle ? { isPartOf: { "@type": "CollectionPage", name: card.department, url: `${ORIGIN}/c/${encodeURIComponent(card.id)}` } } : {}),
      mainEntity: { "@type": "ItemList", numberOfItems: card.count,
        itemListElement: card.products.map((p, i) => ({ "@type": "ListItem", position: i + 1, name: p.title,
          url: `${ORIGIN}/p/${encodeURIComponent(p.id)}` })) },
    }),
  ].join("");
  return html
    .replace(/<title>[^<]*<\/title>/, "")
    .replace(/<meta (property|name)="(og:[^"]+|twitter:card|description)"[^>]*\/>/g, "")
    .replace(/<script type="application\/ld\+json">[\s\S]*?<\/script>/g, "")
    .replace(/<link rel="canonical"[^>]*>/, `<link rel="canonical" href="${escape(url)}"/>`)
    .replace("</head>", `${tags}</head>`);
}

/// marracat.com/app, the link to share the app (owner, 2026-10-09). It used to
/// redirect straight to the App Store, so iMessage previewed Apple's card,
/// which showed an iPad screenshot. This page carries our own card, an iPhone
/// App Store screenshot, then sends people on to the App Store.
export function appSharePage(appStoreURL) {
  const url = "https://marracat.com/app";
  const tags = [
    `<meta property="og:type" content="website"/>`,
    `<meta property="og:site_name" content="Marracat"/>`,
    `<meta property="og:title" content="Marracat"/>`,
    `<meta property="og:description" content="Discover your next favorite"/>`,
    `<meta property="og:url" content="${url}"/>`,
    `<meta property="og:image" content="https://marracat.com/app-preview.jpg"/>`,
    `<meta property="og:image:width" content="828"/>`,
    `<meta property="og:image:height" content="1799"/>`,
    `<meta property="og:image:alt" content="The Marracat app on iPhone"/>`,
    `<meta name="twitter:card" content="summary_large_image"/>`,
    `<meta name="apple-itunes-app" content="app-id=6810905687"/>`,
  ].join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"/>` +
    `<meta name="viewport" content="width=device-width, initial-scale=1"/>` +
    `<title>Marracat on the App Store</title><link rel="canonical" href="${url}"/>${tags}` +
    `<script src="/app-redirect.js" defer></script></head>` +
    `<body style="font-family:-apple-system,sans-serif;text-align:center;padding:48px 16px">` +
    `<p>Opening Marracat in the App Store…</p>` +
    `<p><a data-app-store href="${escape(appStoreURL)}">Get Marracat on the App Store</a></p></body></html>`;
}
