import express from "express";
import { appleMobileAuth } from "./apple-mobile.js";
import { createHash, randomBytes } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { rateLimit } from "express-rate-limit";
import { ownerSighting } from "./owner-metrics.js";
import { accountFor, confirmWith, installIdentitySchema } from "./identities.js";
import { purgeAccount, openBudget } from "./account-delete.js";

const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
const hash = (value) => createHash("sha256").update(value).digest("hex");
const freshProfile = () => ({ saved: [], recentlyViewed: [], recentSearches: [], checkouts: [], hidden: [], personalizationEnabled: true, lists: [] });
const MAX_LISTS = 50;
const text = (v, max = 200) => typeof v === "string" && v.length > 0 && v.length <= max;
const fail = (status, message) => Object.assign(new Error(message), { status });

export async function verifyGoogle(idToken, env = process.env, keySet = googleKeys) {
  if (!env.GOOGLE_IOS_CLIENT_ID || !env.AUTH_GOOGLE_ID) throw fail(503, "Sign-in is not configured");
  if (!text(idToken, 12000)) throw fail(401, "Invalid sign-in token");
  const { payload } = await jwtVerify(idToken, keySet, {
    issuer: ["https://accounts.google.com", "accounts.google.com"],
    audience: env.AUTH_GOOGLE_ID, algorithms: ["RS256"], requiredClaims: ["sub", "exp", "iat"],
    clockTolerance: 5,
  });
  // A token for this server must have been authorized by our iOS or web client.
  if (!text(payload.sub) || ![env.GOOGLE_IOS_CLIENT_ID, env.AUTH_GOOGLE_ID].includes(payload.azp)
      || payload.email_verified !== true || !text(payload.email, 320)) throw fail(401, "Invalid sign-in identity");
  return { id: `google:${payload.sub}`, name: typeof payload.name === "string" ? payload.name.slice(0, 100) : null, email: payload.email };
}

// The signed-in app user behind a Bearer session token, or null. Other routes
// (the order email relay) use it to share the app's sign-in.
export function mobileSessionUser(db, req) {
  const token = req.get("Authorization")?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  const session = token && db.prepare("SELECT user_id FROM mobile_sessions WHERE hash=? AND expires>?").get(hash(token), Date.now());
  const user = session && db.prepare("SELECT id,name,email FROM users WHERE id=?").get(session.user_id);
  return user && db.prepare("SELECT 1 FROM mobile_accounts WHERE user_id=?").get(user.id) ? user : null;
}

export function installMobileSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS mobile_apple_challenges (id TEXT PRIMARY KEY, nonce TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS mobile_accounts (user_id TEXT PRIMARY KEY, generation TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mobile_profiles (user_id TEXT PRIMARY KEY, data TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mobile_sessions (hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS mobile_sessions_user ON mobile_sessions(user_id);
    CREATE TABLE IF NOT EXISTS mobile_operations (user_id TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(user_id,id));
  `);
  // Which sign-in opened the session ("apple:<sub>"), now that one account
  // can have several (identities.js).
  if (!db.prepare("SELECT 1 FROM pragma_table_info('mobile_sessions') WHERE name='identity'").get())
    db.exec("ALTER TABLE mobile_sessions ADD COLUMN identity TEXT");
  installIdentitySchema(db);
}

export function validateOperation(op) {
  if (!op || !text(op.id, 80)) throw fail(400, "Invalid activity identifier");
  if (["save", "unsave", "view", "hide", "unhide"].includes(op.kind)) {
    if (!text(op.value)) throw fail(400, "Invalid product");
  } else if (["search", "removeSearch"].includes(op.kind)) {
    if (!text(op.value, 120) || !op.value.trim()) throw fail(400, "Invalid search");
  } else if (op.kind === "personalization") {
    if (typeof op.enabled !== "boolean") throw fail(400, "Invalid preference");
  } else if (op.kind === "checkout") {
    const c = op.checkout;
    if (!c || !text(c.id, 80) || !text(c.brandID) || !Number.isFinite(c.date)
        || !Number.isInteger(c.itemCount) || c.itemCount < 1 || c.itemCount > 10000
        || !Number.isFinite(c.subtotal) || c.subtotal < 0 || c.subtotal > 1e9
        || !Array.isArray(c.productIDs) || c.productIDs.length > 100 || !c.productIDs.every(x => text(x))
        || (c.orderID != null && !text(c.orderID))
        || (c.total != null && (!Number.isFinite(c.total) || c.total < 0 || c.total > 1e9))
        || (c.items != null && (!Array.isArray(c.items) || c.items.length > 100 || !c.items.every(i => i && text(i.title, 500) && Number.isInteger(i.quantity) && i.quantity > 0 && i.quantity <= 10000)))
        || (c.subtotalCurrency != null && !/^[A-Z]{3}$/.test(c.subtotalCurrency))
        || (c.currency != null && !/^[A-Z]{3}$/.test(c.currency))) throw fail(400, "Invalid checkout record");
  } else if (["listCreate", "listRename"].includes(op.kind)) {
    if (!text(op.value, 80) || !text(op.name, 40) || !op.name.trim()) throw fail(400, "Invalid list");
    // A new folder's id is plain (the app makes UUIDs): it names a file on
    // the phone (CoverPhotos), and "../" in one walked out of its folder
    // until 2026-11-12. Folders that already exist keep whatever id they have.
    if (op.kind === "listCreate" && !/^[A-Za-z0-9_-]+$/.test(op.value)) throw fail(400, "Invalid list");
  } else if (op.kind === "listDelete") {
    if (!text(op.value, 80)) throw fail(400, "Invalid list");
  } else if (["listAdd", "listRemove"].includes(op.kind)) {
    if (!text(op.list, 80) || !text(op.value)) throw fail(400, "Invalid list item");
  } else if (op.kind === "listCover") {
    if (!text(op.list, 80) || (op.value != null && (typeof op.value !== "string" || op.value.length > 200))) throw fail(400, "Invalid list cover");
  } else if (!["clearSearches", "clearHistory", "resetHidden"].includes(op.kind)) throw fail(400, "Unknown activity");
}

export function applyOperation(p, op) {
  if (!Array.isArray(p.lists)) p.lists = [];   // profiles stored before folders existed
  const front = (list, value, limit) => [value, ...list.filter(x => x !== value)].slice(0, limit);
  switch (op.kind) {
    case "save": p.saved = front(p.saved, op.value, 500); p.hidden = p.hidden.filter(x => x !== op.value); break;
    case "unsave":
      p.saved = p.saved.filter(x => x !== op.value);
      for (const l of p.lists) { l.items = l.items.filter(x => x !== op.value); if (l.cover === op.value) l.cover = null; }
      break;
    // Folders of saved items. Items added to a folder are saved by the app in
    // the same batch; removing from a folder leaves the item saved.
    case "listCreate":
      if (!p.lists.some(l => l.id === op.value) && p.lists.length < MAX_LISTS)
        p.lists.push({ id: op.value, name: op.name.trim().slice(0, 40), items: [], cover: null, createdAt: Date.now() / 1000 });
      break;
    case "listRename": { const l = p.lists.find(l => l.id === op.value); if (l) l.name = op.name.trim().slice(0, 40); break; }
    case "listDelete": p.lists = p.lists.filter(l => l.id !== op.value); break;
    case "listAdd": { const l = p.lists.find(l => l.id === op.list); if (l) l.items = front(l.items, op.value, 500); break; }
    case "listRemove": { const l = p.lists.find(l => l.id === op.list); if (l) { l.items = l.items.filter(x => x !== op.value); if (l.cover === op.value) l.cover = null; } break; }
    case "listCover": {
      const l = p.lists.find(l => l.id === op.list);
      if (l) l.cover = !op.value ? null : (op.value === "photo" || l.items.includes(op.value)) ? op.value : l.cover;
      break;
    }
    case "view": if (p.personalizationEnabled) p.recentlyViewed = front(p.recentlyViewed, op.value, 100); break;
    case "search": if (p.personalizationEnabled) p.recentSearches = [op.value, ...p.recentSearches.filter(x => x.toLowerCase() !== op.value.toLowerCase())].slice(0, 30); break;
    case "removeSearch": p.recentSearches = p.recentSearches.filter(x => x.toLowerCase() !== op.value.toLowerCase()); break;
    case "clearSearches": p.recentSearches = []; break;
    case "clearHistory": p.recentSearches = []; p.recentlyViewed = []; break;
    case "hide": p.hidden = front(p.hidden, op.value, 500); break;
    case "unhide": p.hidden = p.hidden.filter(x => x !== op.value); break;
    case "resetHidden": p.hidden = []; break;
    case "personalization": p.personalizationEnabled = op.enabled; if (!op.enabled) { p.recentSearches = []; p.recentlyViewed = []; } break;
    case "checkout": {
      const c = op.checkout;
      // Whitelist fields. Never accept billing addresses, card data or a client-supplied fulfillment status.
      const record = { id: c.id, brandID: c.brandID, date: c.date, itemCount: c.itemCount, subtotal: c.subtotal,
        productIDs: c.productIDs, orderID: c.orderID ?? null, total: c.total ?? null, currency: c.currency ?? null, subtotalCurrency: c.subtotalCurrency ?? null,
        items: c.items?.map(i => ({ title: i.title, quantity: i.quantity })) ?? null };
      if (!p.checkouts.some(x => x.id === c.id || (c.orderID && x.orderID === c.orderID && x.brandID === c.brandID)))
        p.checkouts = [record, ...p.checkouts].slice(0, 200);
      break;
    }
  }
}

/// The account's profile (saved items, lists, history, orders), shared by the
/// app and, since 2026-10-05, the website.
export const loadProfile = (db, id) => JSON.parse(db.prepare("SELECT data FROM mobile_profiles WHERE user_id=?").get(id)?.data || JSON.stringify(freshProfile()));

/// Applies a batch of changes once each (ids are remembered), and saves.
export function applyOperations(db, userID, operations) {
  operations.forEach(validateOperation);
  return db.transaction(() => {
    const p = loadProfile(db, userID);
    for (const op of operations) {
      const inserted = db.prepare("INSERT OR IGNORE INTO mobile_operations(user_id,id) VALUES(?,?)").run(userID, op.id);
      if (inserted.changes) applyOperation(p, op);
    }
    db.prepare("INSERT INTO mobile_profiles(user_id,data) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET data=excluded.data").run(userID, JSON.stringify(p));
    return p;
  })();
}

export function mobileRoutes(app, db, { env = process.env, verify = token => verifyGoogle(token, env), apple = appleMobileAuth(env) } = {}) {
  installMobileSchema(db);
  const sawOwner = ownerSighting(db, env);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60000, limit: 120, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "256kb" }));
  const load = id => JSON.parse(db.prepare("SELECT data FROM mobile_profiles WHERE user_id=?").get(id)?.data || JSON.stringify(freshProfile()));
  const authenticated = (req, res, next) => {
    const token = req.get("Authorization")?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
    const session = token && db.prepare("SELECT user_id,identity FROM mobile_sessions WHERE hash=? AND expires>?").get(hash(token), Date.now());
    const user = session && db.prepare("SELECT id,name,email FROM users WHERE id=?").get(session.user_id);
    if (!user) return res.status(401).json({ error: "Please sign in again" });
    const account = db.prepare("SELECT generation FROM mobile_accounts WHERE user_id=?").get(user.id);
    if (!account) return res.status(401).json({ error: "Please sign in again" });
    req.mobileUser = { ...user, generation: account.generation, signedInWith: session.identity || user.id, confirmWith: confirmWith(db, user.id) };
    req.mobileTokenHash = hash(token);
    sawOwner(user.email, req.ip);
    next();
  };
  // `identity` is the verified sign-in (both verifiers require a verified
  // email when there is one); it opens the account it belongs to.
  const issueSession = (identity, res) => {
    const token = randomBytes(32).toString("hex");
    let accountID;
    db.transaction(() => {
      accountID = accountFor(db, { id: identity.id, email: identity.email, emailVerified: true });
      // A linked sign-in keeps the account's own email; Apple sends no name.
      db.prepare("INSERT INTO users(id,name,email) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=COALESCE(users.name,excluded.name),email=COALESCE(users.email,excluded.email)").run(accountID, identity.name, identity.email);
      db.prepare("INSERT OR IGNORE INTO mobile_accounts(user_id,generation) VALUES(?,?)").run(accountID, randomBytes(16).toString("hex"));
      db.prepare("DELETE FROM mobile_sessions WHERE expires<=?").run(Date.now());
      db.prepare("INSERT INTO mobile_sessions(hash,user_id,expires,identity) VALUES(?,?,?,?)").run(hash(token), accountID, Date.now() + 30*86400000, identity.id);
    })();
    const user = { ...db.prepare("SELECT id,name,email FROM users WHERE id=?").get(accountID) };
    user.generation = db.prepare("SELECT generation FROM mobile_accounts WHERE user_id=?").get(accountID).generation;
    user.signedInWith = identity.id;
    user.confirmWith = confirmWith(db, accountID);
    res.json({ token, user, profile: load(accountID) });
  };
  router.post("/auth/google", rateLimit({ windowMs: 60000, limit: 15, legacyHeaders: false }), async (req, res) => {
    let user;
    try { user = await verify(req.body?.idToken); } catch (e) { return res.status(e.status === 503 ? 503 : 401).json({ error: "Google sign-in could not be verified" }); }
    issueSession(user, res);
  });

  const appleLimit = rateLimit({ windowMs: 60000, limit: 15, legacyHeaders: false });
  const consumeAppleChallenge = body => {
    if (!text(body?.challenge, 64)) throw fail(401, "Start Apple sign-in again");
    const challenge = db.prepare("DELETE FROM mobile_apple_challenges WHERE id=? RETURNING nonce,expires").get(body.challenge);
    if (!challenge || challenge.expires <= Date.now()) throw fail(401, "Start Apple sign-in again");
    return challenge.nonce;
  };
  router.post("/auth/apple/challenge", appleLimit, (req, res) => {
    if (!apple.configured()) return res.status(503).json({ error: "Apple sign-in is not configured" });
    db.prepare("DELETE FROM mobile_apple_challenges WHERE expires<=?").run(Date.now());
    const challenge = randomBytes(32).toString("hex"), nonce = randomBytes(32).toString("hex");
    db.prepare("INSERT INTO mobile_apple_challenges(id,nonce,expires) VALUES(?,?,?)").run(challenge, nonce, Date.now() + 5*60000);
    res.json({ challenge, nonce });
  });
  router.post("/auth/apple", appleLimit, async (req, res) => {
    try {
      const { user } = await apple.authorize(req.body, consumeAppleChallenge(req.body));
      issueSession(user, res);
    } catch (e) { res.status(e.status === 503 ? 503 : 401).json({ error: "Apple sign-in could not be verified" }); }
  });
  router.get("/me", authenticated, (req, res) => res.json({ user: req.mobileUser, profile: load(req.mobileUser.id) }));
  router.post("/activity", authenticated, (req, res) => {
    const operations = req.body?.operations;
    if (!Array.isArray(operations) || operations.length > 100) return res.status(400).json({ error: "Send up to 100 activity changes" });
    res.json({ profile: applyOperations(db, req.mobileUser.id, operations) });
  });
  router.post("/signout", authenticated, (req, res) => {
    db.prepare("DELETE FROM mobile_sessions WHERE hash=?").run(req.mobileTokenHash); res.sendStatus(204);
  });
  router.delete("/account", authenticated, async (req, res) => {
    if (openBudget(db, req.mobileUser.id)) return res.status(409).json({ error: "Cancel your brand's monthly ad budget on marracat.com first, then delete the account." });
    let confirmed;
    let appleGrant;
    try {
      // Any Apple sign-in on the account means Apple's token must be revoked,
      // so Apple confirms it; otherwise Google does.
      if (req.mobileUser.confirmWith === "apple") {
        appleGrant = await apple.authorize(req.body, consumeAppleChallenge(req.body));
        confirmed = appleGrant.user;
      } else { confirmed = await verify(req.body?.idToken); }
    } catch { return res.status(401).json({ error: "Confirm the same sign-in account to delete it" }); }
    const owner = db.prepare("SELECT user_id FROM user_identities WHERE identity=?").get(confirmed.id)?.user_id ?? confirmed.id;
    if (owner !== req.mobileUser.id) return res.status(403).json({ error: "Use the account you are deleting" });
    confirmed = { ...confirmed, id: req.mobileUser.id };
    if (appleGrant) {
      try { await apple.revoke(appleGrant.refreshToken); }
      catch { return res.status(503).json({ error: "Apple access could not be revoked. Please try deletion again." }); }
    }
    purgeAccount(db, confirmed.id);
    res.sendStatus(204);
  });
  router.use((error, req, res, next) => {
    res.status(error.status === 400 || error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500)
      .json({ error: error.status === 400 ? error.message : "Your account could not be updated. Try again." });
  });
  app.use("/api/mobile", router);
}
