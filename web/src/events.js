// What visitors do, sent to our own server (server/events.js). No third-party
// script and no new cookie: the same random id the visit count keeps in
// localStorage. The owner's browser never sends, like the visit count.

function visitorID() {
  if (localStorage.getItem("marracat-owner") === "1") return null;
  let id = localStorage.getItem("marracat-visitor");
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem("marracat-visitor", id);
  }
  return id;
}

export function track(name, data = {}) {
  try {
    const id = visitorID();
    if (!id) return;
    const body = JSON.stringify({ ...data, id, e: name });
    // sendBeacon survives the page being left, which a Buy click usually does.
    const sent = navigator.sendBeacon?.("/api/events", new Blob([body], { type: "application/json" }));
    if (!sent)
      fetch("/api/events", { method: "POST", keepalive: true, headers: { "Content-Type": "application/json" }, body }).catch(() => {});
  } catch {
    /* storage blocked or no beacon: this event just isn't counted */
  }
}

/// The Buy click a link makes, or null: a Shopify cart link, Big Cartel's cart
/// page (/go/bigcartel), a Swell checkout (/go/swell), or a "Shop at <brand>" link to the brand's own site.
/// `brandForHost` maps a store's hostname to its brand id.
export function buyClickFor(href, brandForHost, here = location.origin) {
  let url;
  try {
    url = new URL(href, here);
  } catch {
    return null;
  }
  if (url.origin === new URL(here).origin) {
    const via = { "/go/bigcartel": "bigcartel", "/go/swell": "swell" }[url.pathname];
    if (!via) return null;
    const brand = url.searchParams.get("brand");
    return brand ? { brand, via } : null;
  }
  const brand = brandForHost(url.hostname.replace(/^www\./, ""));
  if (!brand) return null;
  return { brand, via: /^\/cart\/\d+:\d+/.test(url.pathname) ? "cart" : "brand_site" };
}

/// One click listener for every Buy link on the site, however it's drawn.
export function watchBuyClicks(brandForHost) {
  const onClick = (e) => {
    const a = e.target?.closest?.("a[href]");
    if (!a || a.dataset.track === "no") return;
    // A link can name its brand outright (the review page's Pay links go to
    // Shopify checkout hosts that aren't the brand's own domain).
    const buy = a.dataset.trackBrand
      ? { brand: a.dataset.trackBrand, via: a.dataset.trackVia || "brand_site" }
      : buyClickFor(a.getAttribute("href"), brandForHost);
    if (!buy) return;
    track("buy_click", { ...buy, product: a.dataset.trackProduct || undefined });
    // Leaving for a checkout (not just the brand's own store) starts one.
    if (buy.via !== "brand_site") track("checkout_start", { brand: buy.brand, via: buy.via });
  };
  document.addEventListener("click", onClick, true);
  return () => document.removeEventListener("click", onClick, true);
}

// Website pages as the app's screen names (server/EVENTS.md, screen_view).
// Pages with no app counterpart (privacy, support, for brands …) aren't sent.
const LABEL_PAGES = ["/clean", "/true-metal", "/clear-scent", "/safer-clean", "/clean-food", "/baby-safe", "/natural-fiber",
  "/safe-fabric", "/lab-verified", "/pet-safe", "/true-material", "/natural-home"];
export function screenFor(path, params) {
  if (path === "/") return "home";
  if (path === "/shop") {
    const keys = [...params.keys()];
    if (params.get("q")) return "search";
    if (params.get("brand") && keys.every((k) => k === "brand")) return "brand";
    if (params.get("aisle")) return "aisle";
    return "browse";
  }
  if (path === "/brands" || LABEL_PAGES.includes(path)) return "browse";
  return { "/product": "product", "/cart": "cart", "/checkout": "checkout_review", "/account": "account",
    "/saved": "saved", "/boosts": "boosts" }[path] || null;
}

/// checkout_start / checkout_complete props for some cart lines: how many
/// items, and the subtotal when they share one currency (the server buckets
/// it; mixed currencies send none).
export function checkoutProps(lines, via, brand) {
  const items = lines.reduce((n, l) => n + (l.quantity || 0), 0);
  const currencies = new Set(lines.map((l) => l.product?.currency || "USD"));
  const subtotal = currencies.size === 1 ? lines.reduce((n, l) => n + (l.variant?.price || 0) * (l.quantity || 0), 0) : undefined;
  return { via, brand, item_count: Math.max(1, Math.min(99, items)), subtotal };
}
