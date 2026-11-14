// marracat.com's service worker (owner, 2026-11-10: "implement repeat visits
// cache"). It does four small things and leaves everything else alone:
//
//   1. The page shell: asked from the network first; when the network is down
//      or takes over 3 s, the copy kept from the last visit opens instead, so
//      the site still opens offline.
//   2. /assets/ (script, styles, fonts; their names carry a content hash):
//      kept on the device and served from there.
//   3. /api/home and the site's icons: served from the device at once and
//      refreshed in the background for next time.
//   4. Notifications: shows a push and opens its link when tapped.
//
// Never touched: /auth, every other /api path (the catalog keeps its own
// device copy in src/catalog-worker.js), anything that is not a GET, and other
// sites' files such as product photos. Change VERSION to drop every cache.
const VERSION = "v1";
const SHELL = `marracat-shell-${VERSION}`;
const ASSETS = `marracat-assets-${VERSION}`;
const DATA = `marracat-data-${VERSION}`;
const KEEP = new Set([SHELL, ASSETS, DATA]);
const SHELL_URL = "/";
const SHELL_WAIT_MS = 3000;
// Paths the storefront doesn't own (src/router.js SERVER_PATHS): real pages.
const SERVER_PATHS = /^\/(api|auth|go|app|signin|assets|ml|catalog|\.well-known)(\/|$|-|\.)|\.[a-z0-9]{2,5}$/i;
const ICONS = /^\/(favicon[^/]*|apple-touch-icon\.png|icon-[^/]+\.png|mark\.svg|logo\.svg|manifest\.json)$/;

/// The /assets/ files a page shell asks for.
const assetsOf = (html) => [...new Set([...html.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g)].map((m) => m[1]))];

/// Keep a shell, fetch what it needs, and drop assets no shell needs now.
async function keepShell(response) {
  const html = await response.clone().text();
  const wanted = assetsOf(html);
  if (!wanted.length) return; // not the storefront's page
  const assets = await caches.open(ASSETS);
  await Promise.all(wanted.map(async (url) => (await assets.match(url)) || assets.add(url).catch(() => {})));
  await (await caches.open(SHELL)).put(SHELL_URL, response);
  for (const request of await assets.keys()) {
    const path = new URL(request.url).pathname;
    // Fonts are named by the stylesheet, not the shell: they stay.
    if (!wanted.includes(path) && !/\.woff2?$/.test(path)) await assets.delete(request);
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const response = await fetch(SHELL_URL, { cache: "no-cache" });
    if (response.ok) await keepShell(response);
    await self.skipWaiting();
  })().catch(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name.startsWith("marracat-") && !KEEP.has(name) && !name.startsWith("marracat-catalog")) await caches.delete(name);
    await self.registration.navigationPreload?.enable().catch(() => {});
    await self.clients.claim();
  })());
});

async function shell(event) {
  const timeout = new Promise((resolve) => setTimeout(resolve, SHELL_WAIT_MS, null));
  const network = (async () => {
    const response = (await event.preloadResponse) || (await fetch(event.request));
    // The server writes each product, brand and department page's own title
    // into the shell; only the plain home page is kept for offline.
    if (response.ok && new URL(event.request.url).pathname === SHELL_URL) event.waitUntil(keepShell(response.clone()).catch(() => {}));
    // A server error is no better than no answer when a copy is kept.
    return response.status >= 500 ? null : response;
  })().catch(() => null);
  const first = await Promise.race([network, timeout]);
  if (first) return first;
  const kept = await (await caches.open(SHELL)).match(SHELL_URL);
  // Nothing kept yet: wait for the network after all, slow as it is.
  return kept || (await network) || Response.error();
}

async function fromDeviceFirst(request, cacheName) {
  const cache = await caches.open(cacheName);
  const kept = await cache.match(request);
  if (kept) return kept;
  const response = await fetch(request);
  if (response.ok) cache.put(request, response.clone()).catch(() => {});
  return response;
}

async function deviceThenRefresh(event, cacheName) {
  const cache = await caches.open(cacheName);
  const kept = await cache.match(event.request);
  const fresh = fetch(event.request).then((response) => {
    if (response.ok) cache.put(event.request, response.clone()).catch(() => {});
    return response;
  });
  if (!kept) return fresh;
  event.waitUntil(fresh.catch(() => {}));
  return kept;
}

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (request.mode === "navigate") {
    if (!SERVER_PATHS.test(url.pathname)) event.respondWith(shell(event));
    return;
  }
  if (url.pathname.startsWith("/assets/")) return event.respondWith(fromDeviceFirst(request, ASSETS));
  if (url.pathname === "/api/home" || ICONS.test(url.pathname)) return event.respondWith(deviceThenRefresh(event, DATA));
});

// A notification the server sent (server/web-push.js): { title, body, url, tag }.
// A path on this site, or "/". "//host" and "/\\host" both resolve to another
// site (browsers read a backslash as a slash), so a notification could open
// one until 2026-11-12.
function ownPath(u) {
  if (typeof u !== "string" || !/^\/(?![/\\])/.test(u)) return "/";
  try { return new URL(u, self.location.origin).origin === self.location.origin ? u : "/"; } catch { return "/"; }
}

self.addEventListener("push", (event) => {
  let note = {};
  try {
    note = event.data?.json() || {};
  } catch {
    note = { body: event.data?.text() };
  }
  event.waitUntil(self.registration.showNotification(String(note.title || "Marracat").slice(0, 120), {
    body: String(note.body || "").slice(0, 300),
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    tag: note.tag ? String(note.tag).slice(0, 80) : undefined,
    data: { url: ownPath(note.url) },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(ownPath(event.notification.data?.url), self.location.origin).href;
  event.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of open) {
      if ("focus" in client) {
        await client.focus();
        if ("navigate" in client) await client.navigate(url).catch(() => {});
        return;
      }
    }
    await self.clients.openWindow(url);
  })());
});
