// A product's page starts loading when a finger or the pointer goes down on
// its link, not when it comes back up (owner, 2026-11-10: "pre-loading the
// likely next page"). The click that follows is 100-300 ms later, and the
// product page asks for exactly this address, so the browser answers it from
// what is already on its way.
export const productURL = (id) => "/api/products/" + encodeURIComponent(id) + "?v=3";

const asked = new Set();
export function productIDFor(href) {
  const m = /^\/p\/([^/?#]+)\/?$/.exec(String(href || ""));
  if (!m) return null;
  try {
    return decodeURIComponent(m[1]);
  } catch {
    return null;
  }
}

export function preloadProductOnPress(doc = document) {
  // Someone who asked their browser to save data is not sent what they may not open.
  if (navigator.connection?.saveData) return;
  const press = (e) => {
    const id = productIDFor(e.target?.closest?.("a[href]")?.getAttribute("href"));
    if (!id || asked.has(id) || asked.size > 200) return;
    asked.add(id);
    fetch(productURL(id), { priority: "low" }).catch(() => asked.delete(id));
  };
  doc.addEventListener("pointerdown", press, { passive: true });
  doc.addEventListener("touchstart", press, { passive: true });
}
