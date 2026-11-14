// Search engines' map of marracat.com (owner, 2026-10-09: SEO). Before this
// /sitemap.xml and /robots.txt fell through to the storefront's HTML.
//
//   /robots.txt                 everything crawlable except the API, checkout
//                               hand-offs and per-shopper pages
//   /sitemap.xml                a sitemap index
//   /sitemaps/pages.xml         home and the static pages
//   /sitemaps/categories.xml    /c/<department> and /c/<department>/<aisle>
//   /sitemaps/brands.xml        /b/<brand>
//   /sitemaps/products-N.xml    /p/<product>, PRODUCTS_PER_FILE each (Google's
//                               limit is 50,000 URLs per file)
export const PRODUCTS_PER_FILE = 45000;
const ORIGIN = "https://marracat.com";
const xml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[c]);
const day = (generated) => (/^\d{4}-\d{2}-\d{2}/.test(generated || "") ? generated.slice(0, 10) : new Date().toISOString().slice(0, 10));
const PAGES = ["/", "/brands", "/how-it-works", "/for-brands", "/clean", "/true-metal", "/clear-scent", "/safer-clean",
  "/clean-food", "/baby-safe", "/natural-fiber", "/safe-fabric", "/lab-verified", "/pet-safe", "/true-material",
  "/natural-home", "/privacy", "/support"];

export function robotsTxt() {
  return [
    "User-agent: *",
    "Allow: /",
    "Disallow: /api/",
    "Disallow: /auth/",
    "Disallow: /go/",
    "Disallow: /cart",
    "Disallow: /checkout",
    "Disallow: /saved",
    "Disallow: /account",
    "Disallow: /boosts",
    "Disallow: /brand-ads",
    "Disallow: /moderation",
    "Disallow: /shop?",
    "",
    `Sitemap: ${ORIGIN}/sitemap.xml`,
    "",
  ].join("\n");
}

const urlset = (urls, lastmod) =>
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
  urls.map((u) => `<url><loc>${xml(ORIGIN + u)}</loc><lastmod>${lastmod}</lastmod></url>`).join("\n") + "\n</urlset>\n";

export function sitemapIndex(entries) {
  const lastmod = day(entries.generated);
  const files = ["pages", "categories", "brands"];
  const chunks = Math.ceil(entries.products.length / PRODUCTS_PER_FILE);
  for (let i = 1; i <= chunks; i++) files.push(`products-${i}`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
    files.map((f) => `<sitemap><loc>${ORIGIN}/sitemaps/${f}.xml</loc><lastmod>${lastmod}</lastmod></sitemap>`).join("\n") +
    "\n</sitemapindex>\n";
}

// One file of the sitemap by name, or null for a name it doesn't have.
export function sitemapFile(entries, name) {
  const lastmod = day(entries.generated);
  const enc = encodeURIComponent;
  if (name === "pages") return urlset(PAGES, lastmod);
  if (name === "categories")
    return urlset([...entries.categories.map((c) => `/c/${enc(c)}`),
      ...entries.aisles.map((a) => { const [c, leaf] = a.split(":"); return `/c/${enc(c)}/${enc(leaf)}`; })], lastmod);
  if (name === "brands") return urlset(entries.brands.map((b) => `/b/${enc(b)}`), lastmod);
  const m = /^products-(\d{1,4})$/.exec(name);
  if (m) {
    const i = Number(m[1]);
    const slice = entries.products.slice((i - 1) * PRODUCTS_PER_FILE, i * PRODUCTS_PER_FILE);
    if (i < 1 || !slice.length) return null;
    return urlset(slice.map((id) => `/p/${enc(id)}`), lastmod);
  }
  return null;
}
