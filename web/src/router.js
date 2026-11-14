// Real, crawlable addresses for the storefront (owner, 2026-10-09: SEO).
//
// The app's screens are still described by a route string ("/product?id=…",
// "/shop?brand=…&category=…"), but the address bar now carries a path Google
// can index instead of a "#/" hash it ignores:
//
//   /product?id=X                 <-> /p/X
//   /shop?brand=X                 <-> /b/X
//   /shop?category=C              <-> /c/C
//   /shop?category=C&aisle=A      <-> /c/C/A
//   anything else (/brands, /shop?q=…, /u/handle, /)  <-> the same path
//
// Old "#/…" links (shared before this, bookmarks, the app) still work: the hash
// route is read once and the address replaced with its path.

const enc = encodeURIComponent;
const dec = (s) => {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
};

// Route string -> the path shown in the address bar and used in hrefs.
export function toPath(route = "/") {
  let r = String(route || "/");
  if (r.startsWith("#")) r = r.slice(1);
  // One leading slash, never "//host" or "/\\host": those name another site,
  // and history.replaceState throws on them (a "#//evil.example" link took
  // the page down on load until 2026-11-12).
  r = "/" + r.replace(/^[/\\]+/, "");
  const [path, query = ""] = r.split("?");
  const params = new URLSearchParams(query);
  const keys = [...params.keys()];
  const only = (...names) => keys.length === names.length && names.every((n) => params.get(n));
  if (path === "/product" && only("id")) return "/p/" + enc(params.get("id"));
  if (path === "/shop") {
    if (only("brand")) return "/b/" + enc(params.get("brand"));
    if (only("category")) return "/c/" + enc(params.get("category"));
    if (only("category", "aisle")) return "/c/" + enc(params.get("category")) + "/" + enc(params.get("aisle"));
  }
  return query ? path + "?" + query : path;
}

// The address bar (path + query) -> the route string the app renders.
export function fromPath(pathname = "/", search = "") {
  let m = pathname.match(/^\/p\/([^/]+)\/?$/);
  if (m) return "/product?id=" + enc(dec(m[1]));
  m = pathname.match(/^\/b\/([^/]+)\/?$/);
  if (m) return "/shop?brand=" + enc(dec(m[1]));
  m = pathname.match(/^\/c\/([^/]+)(?:\/([^/]+))?\/?$/);
  if (m) {
    const p = new URLSearchParams({ category: dec(m[1]) });
    if (m[2]) p.set("aisle", dec(m[2]));
    return "/shop?" + p.toString();
  }
  const path = pathname.replace(/\/+$/, "") || "/";
  // Tracking and sign-in parameters on the home page aren't part of a route.
  if (path === "/") return "/";
  const query = (search || "").replace(/^\?/, "");
  return query ? path + "?" + query : path;
}

// The route for the current address, upgrading an old "#/…" link in place.
export function currentRoute() {
  if (location.hash.startsWith("#/")) {
    const route = "/" + location.hash.slice(1).replace(/^[/\\]+/, "");
    try { history.replaceState(history.state, "", toPath(route)); } catch {}
    return route;
  }
  return fromPath(location.pathname, location.search);
}

// An href for a route or an old "#/…" string.
export const link = (route) => toPath(route);

// Paths the storefront doesn't own: they load as real pages.
const SERVER_PATHS = /^\/(api|auth|go|app|signin|assets|ml|catalog|\.well-known)(\/|$|-|\.)|\.[a-z0-9]{2,5}$/i;

// The path last announced, so the page knows a move to another page (which
// cross-fades) from a change of filters, sort or search on the same one.
let here = null;
function announce() {
  const page = here !== null && here !== location.pathname;
  here = location.pathname;
  window.dispatchEvent(new CustomEvent("marracat:navigate", { detail: { page } }));
}

export function navigate(route, { replace = false } = {}) {
  const url = toPath(route);
  if (here === null) here = location.pathname;
  if (replace) history.replaceState(history.state, "", url);
  else if (url !== location.pathname + location.search) history.pushState(null, "", url);
  announce();
}

// One listener for the whole page: a plain click on an in-app link changes the
// route without reloading. Modified clicks, new tabs and server paths are left
// to the browser.
export function interceptLinks() {
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest?.("a[href]");
    if (!a || a.target && a.target !== "_self" || a.hasAttribute("download")) return;
    const href = a.getAttribute("href");
    if (!href) return;
    if (href.startsWith("#/")) {
      e.preventDefault();
      navigate(href.slice(1));
      return;
    }
    if (href.startsWith("#")) return; // an in-page anchor (#main)
    let url;
    try {
      url = new URL(href, location.href);
    } catch {
      return;
    }
    if (url.origin !== location.origin || SERVER_PATHS.test(url.pathname)) return;
    e.preventDefault();
    navigate(fromPath(url.pathname, url.search));
  });
  here = location.pathname;
  window.addEventListener("popstate", announce);
  // A hand-typed or old "#/…" address while the page is open.
  window.addEventListener("hashchange", () => {
    if (location.hash.startsWith("#/")) navigate(location.hash.slice(1), { replace: true });
  });
}
