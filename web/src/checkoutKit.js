// Shopify's Checkout Kit for the web (owner, 2026-11-15: "i would like to use
// shopifyes checkout kit for the web"). A Shopify brand's checkout opens in a
// window over marracat.com instead of taking the shopper away from it, and the
// checkout tells this page when the order is placed, so the site knows a
// purchase happened (before, it only knew a shopper left for checkout).
//
// The payment itself still happens on the brand's own Shopify checkout:
// paying on marracat.com needs Shopify's complete_checkout grant, which
// Shopify declined on 2026-10-13 (ticket 71034448).
//
// Popup, never inline: inline embedding needs a Shopify-issued token we don't
// have. Telemetry is off, so nothing extra goes to Shopify from our page.
// Big Cartel and Swell keep their own hand-off (/go/bigcartel, /go/swell).

let ready = null;

/// Loads the component ahead of the click: the popup has to open inside the
/// click itself or browsers block it, so there's no time to fetch code then.
export function preloadCheckoutKit() {
  if (typeof window === "undefined" || !window.customElements) return Promise.resolve(false);
  ready ||= import("@shopify/checkout-kit/shopify-checkout").then(
    () => true,
    () => false,
  );
  return ready;
}

/// A brand checkout Checkout Kit can present: a Shopify brand's https cart
/// permalink or UCP checkout link.
export function kitCheckoutURL(brand, href, here = globalThis.location?.href) {
  if (!brand || !href || !here || (brand.platform && brand.platform !== "shopify")) return null;
  try {
    const url = new URL(href, here);
    if (url.protocol !== "https:" || url.origin === new URL(here).origin) return null;
    return /^\/(cart\/|checkouts\/)/.test(url.pathname) ? url.href : null;
  } catch {
    return null;
  }
}

/// Opens `href` in Checkout Kit's popup when it's loaded and the link fits;
/// returns false otherwise, so the link opens the usual way. Call it from the
/// click handler and preventDefault only on true.
///   onComplete(order)  the store reported an order (order.id when it sends one)
///   onClose(started)   the window closed without an order; started = checkout loaded
export function openCheckoutKit(brand, href, { onComplete, onClose } = {}) {
  const src = kitCheckoutURL(brand, href);
  if (!src || !window.customElements?.get("shopify-checkout")) return false;
  const el = document.createElement("shopify-checkout");
  el.src = src;
  el.target = "popup";
  el.telemetry = false;
  // The checkout can sit on the brand's myshopify.com host after the cart
  // link redirects; the link's own origin is trusted already.
  el.allowedOrigins = ["https://*.myshopify.com"];
  el.style.setProperty("--shopify-checkout-dialog-width", "720");
  el.style.setProperty("--shopify-checkout-dialog-height", "860");
  let started = false;
  let done = false;
  el.addEventListener("start", () => { started = true; });
  el.addEventListener("complete", (event) => {
    done = true;
    onComplete?.(event.detail?.checkout?.order || null);
  });
  el.addEventListener("error", (event) => {
    // A browser too old for the component: go the usual way, in a new tab.
    if (event.detail?.error?.code === "unsupported_browser") window.open(src, "_blank", "noopener");
  });
  el.addEventListener("close", () => {
    if (!done) onClose?.(started);
    el.remove();
  });
  document.body.append(el);
  el.open();
  return true;
}
