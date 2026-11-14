import express from "express";
import { ExpressAuth } from "@auth/express";
import { rateLimit } from "express-rate-limit";
import Database from "better-sqlite3";
import { mkdirSync, existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { createAuthConfig, authStatus } from "./auth.js";
import { catalogRoutes, catalogLoaded, shareCard, brandCard, brandForDomain, categoryCard, sitemapEntries, querySource } from "./catalog.js";
import { queryRoutes } from "./query.js";
import { vitalsRoutes } from "./vitals.js";
import { checkoutRoutes } from "./checkout.js";
import { sharePage, brandSharePage, appSharePage, categorySharePage } from "./share-page.js";
import { robotsTxt, sitemapIndex, sitemapFile } from "./seo.js";
import { shopifyRoutes } from "./shopify.js";
import { iosAppRoutes, IOS_APP_URL } from "./ios-app.js";
import { mapkitRoutes } from "./mapkit.js";
import { brandClaimRoutes } from "./brand-claims.js";
import { farmWatch, visitRoutes } from "./visits.js";
import { eventRoutes } from "./events.js";
import { trendingRoutes } from "./trending.js";
import { commentFeedRoutes } from "./comment-feed.js";
import { boostRoutes } from "./boosts.js";
import { budgetRoutes } from "./boost-budgets.js";
import { bigCartelRoutes } from "./bigcartel.js";
import { swellRoutes } from "./swell.js";
import { dealAlertRoutes } from "./deal-alerts.js";
import { webPushRoutes, webPushSender } from "./web-push.js";
import { passkeyRoutes } from "./passkeys.js";
import { cartRoutes } from "./cart-sync.js";
import { accountWebRoutes } from "./account-web.js";
import { sponsoredRoutes } from "./sponsored.js";
import { mobileRoutes, mobileSessionUser } from "./mobile.js";
import { ownerMetricsRoutes } from "./owner-metrics.js";
import { socialRoutes, viewerOf } from "./social.js";
import { restockRoutes, restockMailer, apnsSender } from "./restock.js";
import { emailCodeRoutes } from "./email-code.js";
import { fxRoutes } from "./fx-rates.js";
import { trackingRoutes } from "./order-tracking.js";
import { lateShipmentRoutes } from "./late-shipments.js";
import { appMetricsRoutes } from "./app-metrics.js";
import { pairingsRoutes } from "./pairings.js";
import { complementRoutes } from "./complements.js";
import { liveStockRoutes } from "./live-stock.js";
import { brandFreshRoutes } from "./brand-fresh.js";
import { createRelay, relayRoutes, startRelaySMTP } from "./relay.js";
import { trackingPoller, POLL_EVERY_MS } from "./tracking-poll.js";
import { syncRelayOrders } from "./relay-sync.js";
import { liveActivityRoutes } from "./live-activity.js";
import { sameSiteWrites } from "./same-site.js";
const here = path.dirname(fileURLToPath(import.meta.url));
const app = express();
const port = Number(process.env.PORT || 3107);
const dataDir = process.env.DATA_DIR || path.join(here, "../data");
mkdirSync(dataDir, { recursive: true, mode: 0o700 });
const db = new Database(path.join(dataDir, "marracat.sqlite"));
db.pragma("journal_mode = WAL");
db.exec(
  "CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, name TEXT, email TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
);
app.disable("x-powered-by");
app.set("trust proxy", "loopback");
app.use((req, res, next) => {
  if (process.env.NODE_ENV === "production" && req.hostname !== "marracat.com")
    return res.sendStatus(400);
  res.set("X-Content-Type-Options", "nosniff");
  next();
});
// A signed-in browser's writes come from our own pages or not at all (same-site.js).
app.use(sameSiteWrites());
catalogRoutes(app);
queryRoutes(app, querySource);
checkoutRoutes(app, { viewer: (req) => viewerOf(req, db, process.env) });
shopifyRoutes(app);
mobileRoutes(app, db);
const stock = liveStockRoutes(app);
brandFreshRoutes(app, { db });
restockRoutes(app, db, { onLive: stock.prime });
// Order emails move the app's tracked orders (relay-sync.js): after each
// email or tracker update, when an order is registered, and every 10 minutes.
const syncOrders = () => syncRelayOrders(db, { brandFor: brandForDomain, log: (m) => console.log(m) });
const orderTracking = trackingRoutes(app, db, { onRegister: syncOrders });
lateShipmentRoutes(app, db);
appMetricsRoutes(app, db);
pairingsRoutes(app, db);
complementRoutes(app, db);
// The Marracat order email: u-…@orders.marracat.com (see relay.js).
const relay = createRelay(db, { brandFor: brandForDomain, onChange: syncOrders });
setTimeout(() => { try { syncOrders(); } catch (e) { console.error("Order email sync failed:", e.name); } }, 30_000).unref();
setInterval(() => { try { syncOrders(); } catch (e) { console.error("Order email sync failed:", e.name); } }, 10 * 60_000).unref();
relayRoutes(app, db, relay, { track17: [orderTracking.track17Update], easypost: [orderTracking.easyPostUpdate] });
startRelaySMTP(relay, db);
// Today's deliveries in the Dynamic Island (live-activity.js): one Live
// Activity per phone, synced every 2 minutes from what the trackers know.
liveActivityRoutes(app, db);
// Every undelivered tracking number, asked of 17TRACK every 10 minutes
// (tracking-poll.js); answers go through the same handlers as its pushes.
const poller = trackingPoller(db, { listeners: [relay.track17Update, orderTracking.track17Update] });
if (process.env.NODE_ENV === "production") {
  const pollNow = () => poller.poll().then((r) => r.asked && console.log(`17TRACK poll: ${r.answered}/${r.asked} answered`))
    .catch((e) => console.error("17TRACK poll failed:", e.name));
  setTimeout(pollNow, 60_000).unref();
  setInterval(pollNow, POLL_EVERY_MS).unref();
}
// "Arriving today" on the expected day's morning (relay.js), checked every 15 minutes.
if (process.env.NODE_ENV === "production")
  setInterval(() => relay.morningNotes().then((n) => n && console.log(`Arriving today: ${n} sent`)).catch((e) => console.error("Arriving-today check failed:", e.name)), 15 * 60_000).unref();
app.use(
  "/api/social",
  rateLimit({ windowMs: 60_000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }),
);
socialRoutes(app, db);
ownerMetricsRoutes(app);
// Marracat's UCP agent profile. Every checkout call to a brand's store names
// this URL in meta["ucp-agent"].profile, and the store fetches it to learn
// what the app can handle (checkout, shipping, discounts, buyer consent).
const ucpProfile = readFileSync(path.join(here, "ucp-profile.json"), "utf8");
app.get("/.well-known/ucp", (_, res) => {
  res.set("Cache-Control", "public, max-age=3600").type("application/json").send(ucpProfile);
});
iosAppRoutes(app);
mapkitRoutes(app);
brandClaimRoutes(app, db, { mailer: restockMailer() });
emailCodeRoutes(app, db, { mailer: restockMailer() });
// One bot-farm watcher for visits and events, so a block caught by either is out of both.
const isFarm = farmWatch(db);
visitRoutes(app, db, { viewer: (req) => viewerOf(req, db, process.env), isFarm });
eventRoutes(app, db, { viewer: (req) => viewerOf(req, db, process.env), appViewer: (req) => mobileSessionUser(db, req), isFarm });
vitalsRoutes(app, db);
commentFeedRoutes(app, db, { card: shareCard, viewer: (req) => viewerOf(req, db, process.env) });
trendingRoutes(app, db);
boostRoutes(app, db, { viewer: (req) => viewerOf(req, db, process.env) });
budgetRoutes(app, db, { viewer: (req) => viewerOf(req, db, process.env) });
bigCartelRoutes(app);
swellRoutes(app);
passkeyRoutes(app, db, { viewer: (req) => viewerOf(req, db, process.env) });
// Notifications in a browser (server/web-push.js); null until its keys are installed.
const webPush = webPushSender();
webPushRoutes(app, db, { sender: webPush, viewer: (req) => viewerOf(req, db, process.env) });
dealAlertRoutes(app, db, { apns: apnsSender(), mail: restockMailer(), webPush });
cartRoutes(app, db);
accountWebRoutes(app, db, { relay, mailer: restockMailer() });
sponsoredRoutes(app, db);
fxRoutes(app);
app.get("/api/health", (_, res) => res.json({ ok: true }));
app.get("/api/auth-status", (_, res) => {
  res.set("Cache-Control", "no-store");
  res.json(authStatus());
});
// The account page at its real address; "/?error=…#/account" lost the error
// when the storefront upgraded the hash link (SEO paths, 2026-10-09).
app.get("/signin", (req, res) =>
  res.redirect(
    "/account?error=" +
      encodeURIComponent(
        typeof req.query.error === "string" ? req.query.error : "Signin",
      ),
  ),
);
app.use(
  "/auth",
  rateLimit({
    windowMs: 60_000,
    // AUTH_RATE_LIMIT only for a local test server: a full journey run comes
    // from one address and passes 60 session checks a minute (2026-11-10).
    limit: Number(process.env.AUTH_RATE_LIMIT) || 60,
    standardHeaders: "draft-8",
    legacyHeaders: false,
  }),
);
app.use("/auth", (req, res, next) => {
  res.set("Cache-Control", "no-store");
  next();
});
// The Apple client secret is renewed every 45 minutes (auth.js), so it never expires on a long-running process.
app.use(/^\/auth\/(.*)/, async (req, res, next) => {
  try {
    const config = await createAuthConfig(db);
    return ExpressAuth(config)(req, res, next);
  } catch (error) {
    console.error("Auth configuration failed:", error.name);
    res.status(503).json({ error: "Sign-in is temporarily unavailable" });
  }
});
// In production nginx serves the existing live catalog proxy, unchanged.
if (process.env.NODE_ENV !== "production")
  app.get("/catalog.json", (_, res) =>
    res.sendFile(path.resolve(here, "../../Marracat/Resources/catalog.json")),
  );
const dist = path.resolve(here, "../dist");
if (existsSync(dist)) {
  app.use(express.static(dist, { index: false }));
  const shell = readFileSync(path.join(dist, "index.html"), "utf8");
  // A removed brand or product answers 404 (still the app shell, so people land
  // somewhere) so search engines drop it; before the catalog loads, 200 as before.
  const found = (card) => (card || !catalogLoaded() ? 200 : 404);
  app.get("/p/:id", (req, res) => {
    const card = shareCard(req.params.id);
    res.set("Cache-Control", "public, max-age=300");
    res.status(found(card)).type("html").send(sharePage(shell, card));
  });
  app.get("/b/:id", (req, res) => {
    const card = brandCard(req.params.id);
    res.set("Cache-Control", "public, max-age=300");
    res.status(found(card)).type("html").send(brandSharePage(shell, card));
  });
  // Department pages, real paths Google can index (owner, 2026-10-09: SEO).
  const category = (req, res) => {
    const card = categoryCard(req.params.cat, req.params.aisle || "");
    res.set("Cache-Control", "public, max-age=300");
    res.status(card ? 200 : 404).type("html").send(categorySharePage(shell, card));
  };
  app.get("/c/:cat", category);
  app.get("/c/:cat/:aisle", category);
  // The search engines' map (seo.js), rebuilt from the catalog in memory.
  app.get("/robots.txt", (_, res) => res.set("Cache-Control", "public, max-age=3600").type("text/plain").send(robotsTxt()));
  app.get("/sitemap.xml", (_, res) =>
    res.set("Cache-Control", "public, max-age=3600").type("application/xml").send(sitemapIndex(sitemapEntries())));
  app.get("/sitemaps/:name.xml", (req, res) => {
    const body = sitemapFile(sitemapEntries(), req.params.name);
    if (!body) return res.status(404).type("text/plain").send("Not found");
    res.set("Cache-Control", "public, max-age=3600").type("application/xml").send(body);
  });
  // The website banner's QR code. With the app installed, iOS opens it here
  // instead (a universal link, see nginx.conf); otherwise the App Store.
  // With the app installed, iOS opens it here instead (a universal link); the
  // page itself gives link previews our own iPhone card (share-page.js).
  app.get("/app", (_, res) => {
    res.set("Cache-Control", "public, max-age=300");
    res.type("html").send(appSharePage(IOS_APP_URL));
  });
  app.get("/{*path}", (_, res) => res.sendFile(path.join(dist, "index.html")));
}
app.use((error, req, res, next) => {
  console.error("Request failed:", error.name);
  res.status(500).json({ error: "Request could not be completed" });
});
const server = app.listen(port, "127.0.0.1", () =>
  console.log(`Marracat listening on 127.0.0.1:${port}`),
);
for (const signal of ["SIGTERM", "SIGINT"])
  process.on(signal, () =>
    server.close(() => {
      db.close();
      process.exit(0);
    }),
  );
