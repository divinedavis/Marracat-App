import express from "express";
import { randomBytes, createHash } from "node:crypto";
import { getSession } from "@auth/express";
import { createAuthConfig } from "./auth.js";
import { isOwnerEmail } from "./owner-metrics.js";
import { refusal } from "./content-filter.js";

// Comments, profiles, friends and sharing, for the website and the app alike.
//
// One router at /api/social serves both. The app authenticates with the same
// bearer token as /api/mobile; the website with its Auth.js session cookie. A
// Google account is the same user on both, because both key it as
// "google:<sub>".
//
// Nothing here ever returns an email or an internal user id. People are known
// to each other by a profile: a display name and a unique @handle.
//
// Products shared between friends are end-to-end encrypted. Each device makes
// its own P-256 key pair and only ever sends the public half here; a share is
// sealed separately for every device of the recipient (ECDH with a fresh
// ephemeral key, HKDF-SHA256, AES-256-GCM; see src/e2ee.js and the app's
// ShareCrypto.swift, which agree byte for byte). This server stores who sent
// to whom and when, and ciphertext it cannot read. It can't filter what it
// can't read, so the language filter runs on the sender's device, and a
// report carries the one message the reporter's own device decrypted.
//
// The App Store requires apps with user-generated content to filter it, let
// people report it and block abusive users, have them agree to terms first, and
// act on reports within 24 hours (Guideline 1.2). Those are built in, not
// bolted on: the filter is content-filter.js, a report hides the content at
// once until the owner reviews it, a block hides both people from each other
// everywhere here, posting needs agreed terms, and /moderation is the queue.

const now = () => Date.now();
const newID = () => randomBytes(12).toString("base64url");
const hash = (value) => createHash("sha256").update(value).digest("hex");
const fail = (status, message, code) => Object.assign(new Error(message), { status, code });
const text = (v, max) => typeof v === "string" && v.trim().length > 0 && v.length <= max;

export const LIMITS = {
  comment: 1000,
  note: 280,
  name: 40,
  reason: 500,
  // per person, per window
  commentsPer10Min: 10,
  sharesPer10Min: 30,
  requestsPerHour: 30,
  reportsPerHour: 20,
  likesPerHour: 300,
};

const HANDLE = /^[a-z0-9_]{3,20}$/;
const RESERVED = new Set(["admin", "administrator", "marracat", "support", "help", "owner", "staff",
  "moderator", "mod", "official", "team", "system", "root", "null", "undefined", "me", "you"]);

export function installSocialSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS profiles (user_id TEXT PRIMARY KEY, handle TEXT NOT NULL UNIQUE, display_name TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS ugc_terms (user_id TEXT PRIMARY KEY, agreed_at INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS comments (id TEXT PRIMARY KEY, product_id TEXT NOT NULL, user_id TEXT, parent_id TEXT,
      body TEXT NOT NULL, created_at INTEGER NOT NULL, hidden_at INTEGER, deleted_at INTEGER);
    CREATE INDEX IF NOT EXISTS comments_product ON comments(product_id, created_at);
    CREATE INDEX IF NOT EXISTS comments_parent ON comments(parent_id);
    CREATE INDEX IF NOT EXISTS comments_user ON comments(user_id, created_at);
    CREATE TABLE IF NOT EXISTS blocks (user_id TEXT NOT NULL, blocked_id TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(user_id, blocked_id));
    CREATE TABLE IF NOT EXISTS reports (id TEXT PRIMARY KEY, reporter_id TEXT NOT NULL, kind TEXT NOT NULL, target_id TEXT NOT NULL,
      reason TEXT, evidence TEXT, created_at INTEGER NOT NULL, resolved_at INTEGER, resolution TEXT);
    CREATE INDEX IF NOT EXISTS reports_open ON reports(resolved_at, created_at);
    CREATE TABLE IF NOT EXISTS friend_requests (from_id TEXT NOT NULL, to_id TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(from_id, to_id));
    CREATE TABLE IF NOT EXISTS friends (a TEXT NOT NULL, b TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(a, b));
    CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, user_id TEXT NOT NULL, public_key TEXT NOT NULL,
      created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
    CREATE TABLE IF NOT EXISTS shares (id TEXT PRIMARY KEY, from_id TEXT NOT NULL, to_id TEXT NOT NULL,
      created_at INTEGER NOT NULL, seen_at INTEGER);
    CREATE INDEX IF NOT EXISTS shares_to ON shares(to_id, created_at);
    CREATE TABLE IF NOT EXISTS share_envelopes (share_id TEXT NOT NULL, device_id TEXT NOT NULL, ephemeral_key TEXT NOT NULL,
      nonce TEXT NOT NULL, ciphertext TEXT NOT NULL, PRIMARY KEY(share_id, device_id));
    CREATE TABLE IF NOT EXISTS user_flags (user_id TEXT PRIMARY KEY, suspended_at INTEGER);
    CREATE TABLE IF NOT EXISTS comment_likes (comment_id TEXT NOT NULL, user_id TEXT NOT NULL, created_at INTEGER NOT NULL,
      PRIMARY KEY(comment_id, user_id));
    CREATE INDEX IF NOT EXISTS comment_likes_user ON comment_likes(user_id, created_at);
  `);
}

/** Everything social about a person, for account deletion. Their comments are
 * emptied rather than removed, so other people's replies keep their thread. */
export function deleteSocialData(db, userID) {
  installSocialSchema(db);
  db.prepare("UPDATE comments SET body='', deleted_at=?, user_id=NULL WHERE user_id=?").run(now(), userID);
  db.prepare("DELETE FROM share_envelopes WHERE share_id IN (SELECT id FROM shares WHERE from_id=? OR to_id=?)").run(userID, userID);
  db.prepare("DELETE FROM share_envelopes WHERE device_id IN (SELECT id FROM devices WHERE user_id=?)").run(userID);
  for (const [table, cols] of [["profiles", ["user_id"]], ["ugc_terms", ["user_id"]], ["blocks", ["user_id", "blocked_id"]],
    ["friend_requests", ["from_id", "to_id"]], ["friends", ["a", "b"]], ["shares", ["from_id", "to_id"]],
    ["reports", ["reporter_id"]], ["user_flags", ["user_id"]], ["devices", ["user_id"]], ["comment_likes", ["user_id"]]])
    for (const col of cols) db.prepare(`DELETE FROM ${table} WHERE ${col}=?`).run(userID);
}

// --- who is asking -------------------------------------------------------------

export async function viewerOf(req, db, env) {
  const bearer = req.get("Authorization")?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  if (bearer) {
    const s = db.prepare("SELECT user_id FROM mobile_sessions WHERE hash=? AND expires>?").get(hash(bearer), now());
    const user = s && db.prepare("SELECT id,name,email FROM users WHERE id=?").get(s.user_id);
    return user ? { ...user, via: "app" } : null;
  }
  try {
    const session = await getSession(req, await createAuthConfig(db, env));
    const id = session?.user?.id;
    const user = id && db.prepare("SELECT id,name,email FROM users WHERE id=?").get(id);
    return user ? { ...user, via: "web", sid: session.user.sid || null } : null;
  } catch {
    return null;
  }
}

// --- profiles ------------------------------------------------------------------

/** "Divine Davis" becomes "Divine D.": enough to recognise a friend, not a
 * full name shown to strangers by default. People can change it. */
function defaultName(name) {
  const parts = String(name || "").trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return "Marracat shopper";
  return (parts.length > 1 ? `${parts[0]} ${parts.at(-1)[0].toUpperCase()}.` : parts[0]).slice(0, LIMITS.name);
}

function ensureProfile(db, user) {
  const existing = db.prepare("SELECT * FROM profiles WHERE user_id=?").get(user.id);
  if (existing) return existing;
  const display = defaultName(user.name);
  const stem = display.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 12) || "shopper";
  for (let i = 0; i < 20; i++) {
    const handle = `${stem.length >= 3 ? stem : stem + "shop"}${Math.floor(1000 + Math.random() * 9000)}`;
    try {
      db.prepare("INSERT INTO profiles(user_id,handle,display_name,created_at) VALUES(?,?,?,?)").run(user.id, handle, display, now());
      return db.prepare("SELECT * FROM profiles WHERE user_id=?").get(user.id);
    } catch (e) {
      if (!String(e.message).includes("UNIQUE")) throw e;
    }
  }
  throw fail(500, "A profile could not be created");
}

const publicProfile = (p) => (p ? { handle: p.handle, name: p.display_name } : null);

function profileByHandle(db, handle) {
  const h = String(handle || "").replace(/^@/, "").toLowerCase();
  return HANDLE.test(h) ? db.prepare("SELECT * FROM profiles WHERE handle=?").get(h) : null;
}

// --- relationships -------------------------------------------------------------

const pair = (x, y) => (x < y ? [x, y] : [y, x]);
function blockedEitherWay(db, x, y) {
  return !!db.prepare("SELECT 1 FROM blocks WHERE (user_id=? AND blocked_id=?) OR (user_id=? AND blocked_id=?)").get(x, y, y, x);
}
function areFriends(db, x, y) {
  const [a, b] = pair(x, y);
  return !!db.prepare("SELECT 1 FROM friends WHERE a=? AND b=?").get(a, b);
}
function relationship(db, me, them) {
  if (me === them) return "self";
  if (db.prepare("SELECT 1 FROM blocks WHERE user_id=? AND blocked_id=?").get(me, them)) return "blocked";
  if (areFriends(db, me, them)) return "friends";
  if (db.prepare("SELECT 1 FROM friend_requests WHERE from_id=? AND to_id=?").get(me, them)) return "requested";
  if (db.prepare("SELECT 1 FROM friend_requests WHERE from_id=? AND to_id=?").get(them, me)) return "incoming";
  return "none";
}
/** Everyone this person has blocked or been blocked by. */
function blockedSet(db, me) {
  if (!me) return new Set();
  return new Set(db.prepare("SELECT blocked_id AS id FROM blocks WHERE user_id=? UNION SELECT user_id FROM blocks WHERE blocked_id=?")
    .all(me, me).map((r) => r.id));
}

function countSince(db, sql, id, since) {
  return db.prepare(sql).get(id, since).n;
}

// --- comments ------------------------------------------------------------------

function threadsFor(db, productID, viewer, owner) {
  const blocked = blockedSet(db, viewer?.id);
  const rows = db.prepare(`SELECT c.*, p.handle, p.display_name FROM comments c LEFT JOIN profiles p ON p.user_id=c.user_id
    WHERE c.product_id=? ORDER BY c.created_at ASC LIMIT 2000`).all(productID);
  const visible = (c) => !c.deleted_at && !(c.user_id && blocked.has(c.user_id))
    && (!c.hidden_at || owner || (viewer && c.user_id === viewer.id));
  // Likes (owner, 2026-11-04: "we need to allow likes"): how many, and
  // whether the person asking is one of them. Likes from people they've
  // blocked, or who blocked them, still count; who liked is never shown.
  const likes = new Map(db.prepare(`SELECT l.comment_id AS id, COUNT(*) AS n FROM comment_likes l
    JOIN comments c ON c.id=l.comment_id WHERE c.product_id=? GROUP BY l.comment_id`).all(productID).map((r) => [r.id, r.n]));
  const liked = new Set(viewer ? db.prepare(`SELECT l.comment_id AS id FROM comment_likes l
    JOIN comments c ON c.id=l.comment_id WHERE c.product_id=? AND l.user_id=?`).all(productID, viewer.id).map((r) => r.id) : []);
  const shape = (c) => ({
    id: c.id,
    // A removed comment names no one: its author took it down.
    author: !c.deleted_at && c.user_id && c.handle ? { handle: c.handle, name: c.display_name } : null,
    body: c.deleted_at ? "" : c.body,
    created_at: c.created_at,
    mine: !!viewer && c.user_id === viewer.id,
    deleted: !!c.deleted_at,
    // Only the author and the owner see their own hidden comment, marked.
    under_review: !!c.hidden_at,
    likes: c.deleted_at ? 0 : likes.get(c.id) ?? 0,
    liked: !c.deleted_at && liked.has(c.id),
  });
  const replies = new Map();
  for (const c of rows) if (c.parent_id && visible(c)) (replies.get(c.parent_id) ?? replies.set(c.parent_id, []).get(c.parent_id)).push(shape(c));
  const threads = [];
  for (const c of rows) {
    if (c.parent_id) continue;
    const kids = (replies.get(c.id) ?? []).slice(0, 100);
    if (visible(c)) threads.push({ ...shape(c), replies: kids });
    // A deleted comment with replies stays as a placeholder so its thread
    // still makes sense; with none it simply goes.
    else if (c.deleted_at && kids.length) threads.push({ ...shape(c), replies: kids });
  }
  return threads.reverse().slice(0, 200); // newest threads first, replies oldest first
}

// --- routes --------------------------------------------------------------------

export function socialRoutes(app, db, { env = process.env, viewer = (req) => viewerOf(req, db, env) } = {}) {
  installSocialSchema(db);
  const router = express.Router();
  const production = env.NODE_ENV === "production";
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(express.json({ limit: "32kb" }));

  // Resolve the person, and refuse a cookie-authenticated write that didn't
  // come from marracat.com's own pages. The session cookie is SameSite=Lax
  // already; this is the second lock.
  router.use(async (req, res, next) => {
    try {
      req.viewer = await viewer(req);
    } catch {
      req.viewer = null;
    }
    if (req.viewer?.via === "web" && req.method !== "GET") {
      const origin = req.get("Origin") || "";
      const allowed = production ? origin === "https://marracat.com" : !origin || /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(origin);
      if (!allowed) return res.status(403).json({ error: "Request refused" });
    }
    if (req.viewer && db.prepare("SELECT 1 FROM user_flags WHERE user_id=? AND suspended_at IS NOT NULL").get(req.viewer.id) && req.method !== "GET")
      return res.status(403).json({ error: "This account can no longer post on Marracat." });
    next();
  });
  const signedIn = (req, res, next) => (req.viewer ? next() : res.status(401).json({ error: "Sign in to do that" }));
  const isOwner = (req) => !!req.viewer && isOwnerEmail(req.viewer.email, env);
  const agreed = (id) => !!db.prepare("SELECT 1 FROM ugc_terms WHERE user_id=?").get(id);
  const needsTerms = (req) => {
    if (!agreed(req.viewer.id)) throw fail(428, "Agree to the community guidelines first", "terms_required");
  };
  const target = (req) => {
    const p = profileByHandle(db, req.params.handle);
    if (!p || blockedEitherWay(db, req.viewer?.id ?? "", p.user_id) && relationship(db, req.viewer?.id, p.user_id) !== "blocked")
      throw fail(404, "No one by that name");
    return p;
  };

  // --- you -----------------------------------------------------------------------
  router.get("/me", signedIn, (req, res) => {
    const me = req.viewer.id, profile = ensureProfile(db, req.viewer);
    res.json({
      profile: publicProfile(profile),
      agreed_terms: agreed(me),
      owner: isOwner(req),
      counts: {
        incoming: db.prepare("SELECT COUNT(*) n FROM friend_requests WHERE to_id=?").get(me).n,
        unseen_shares: db.prepare("SELECT COUNT(*) n FROM shares WHERE to_id=? AND seen_at IS NULL").get(me).n,
        // Only the owner is told how many reports are waiting; they have 24
        // hours to act on each (App Store 1.2).
        ...(isOwner(req) ? { reports: db.prepare("SELECT COUNT(*) n FROM reports WHERE resolved_at IS NULL").get().n } : {}),
      },
    });
  });
  router.patch("/me", signedIn, (req, res) => {
    const profile = ensureProfile(db, req.viewer);
    let { name, handle } = req.body || {};
    if (name != null) {
      if (!text(name, LIMITS.name)) throw fail(400, `Names are 1 to ${LIMITS.name} characters`);
      name = name.trim().replace(/\s+/g, " ");
      const why = refusal(name);
      if (why) throw fail(422, why);
    }
    if (handle != null) {
      handle = String(handle).replace(/^@/, "").toLowerCase();
      if (!HANDLE.test(handle)) throw fail(400, "Handles are 3 to 20 letters, numbers or underscores");
      if (RESERVED.has(handle) || refusal(handle)) throw fail(422, "That handle isn't available");
      const taken = db.prepare("SELECT user_id FROM profiles WHERE handle=?").get(handle);
      if (taken && taken.user_id !== req.viewer.id) throw fail(409, "That handle is taken");
    }
    db.prepare("UPDATE profiles SET display_name=COALESCE(?,display_name), handle=COALESCE(?,handle) WHERE user_id=?")
      .run(name ?? null, handle ?? null, profile.user_id);
    res.json({ profile: publicProfile(db.prepare("SELECT * FROM profiles WHERE user_id=?").get(req.viewer.id)) });
  });
  router.post("/terms", signedIn, (req, res) => {
    if (req.body?.agree !== true) throw fail(400, "Agree to continue");
    db.prepare("INSERT OR IGNORE INTO ugc_terms(user_id,agreed_at) VALUES(?,?)").run(req.viewer.id, now());
    ensureProfile(db, req.viewer);
    res.json({ agreed_terms: true });
  });

  // --- people --------------------------------------------------------------------
  router.get("/users/:handle", (req, res) => {
    const p = target(req);
    res.json({ profile: publicProfile(p), relationship: req.viewer ? relationship(db, req.viewer.id, p.user_id) : "none" });
  });
  router.get("/search", signedIn, (req, res) => {
    const q = String(req.query.q || "").replace(/^@/, "").trim().toLowerCase();
    if (q.length < 2 || q.length > 40) return res.json({ people: [] });
    const blocked = blockedSet(db, req.viewer.id);
    const like = q.replace(/[%_\\]/g, "\\$&") + "%";
    const found = db.prepare(`SELECT * FROM profiles WHERE (handle LIKE ? ESCAPE '\\' OR lower(display_name) LIKE ? ESCAPE '\\')
      AND user_id<>? LIMIT 40`).all(like, like, req.viewer.id).filter((p) => !blocked.has(p.user_id)).slice(0, 20);
    res.json({ people: found.map((p) => ({ ...publicProfile(p), relationship: relationship(db, req.viewer.id, p.user_id) })) });
  });

  // --- friends -------------------------------------------------------------------
  router.get("/friends", signedIn, (req, res) => {
    const me = req.viewer.id;
    const list = (sql, ...a) => db.prepare(sql).all(...a).map(publicProfile);
    res.json({
      friends: list(`SELECT p.* FROM friends f JOIN profiles p ON p.user_id = CASE WHEN f.a=? THEN f.b ELSE f.a END
        WHERE f.a=? OR f.b=? ORDER BY lower(p.display_name)`, me, me, me),
      incoming: list("SELECT p.* FROM friend_requests r JOIN profiles p ON p.user_id=r.from_id WHERE r.to_id=? ORDER BY r.created_at DESC", me),
      outgoing: list("SELECT p.* FROM friend_requests r JOIN profiles p ON p.user_id=r.to_id WHERE r.from_id=? ORDER BY r.created_at DESC", me),
    });
  });
  // Send a request, or accept theirs if they already asked.
  router.post("/users/:handle/friend", signedIn, (req, res) => {
    const me = req.viewer.id, them = target(req).user_id;
    ensureProfile(db, req.viewer);
    if (them === me) throw fail(400, "That's you");
    if (blockedEitherWay(db, me, them)) throw fail(404, "No one by that name");
    if (areFriends(db, me, them)) return res.json({ relationship: "friends" });
    if (db.prepare("SELECT 1 FROM friend_requests WHERE from_id=? AND to_id=?").get(them, me)) {
      const [a, b] = pair(me, them);
      db.transaction(() => {
        db.prepare("DELETE FROM friend_requests WHERE (from_id=? AND to_id=?) OR (from_id=? AND to_id=?)").run(me, them, them, me);
        db.prepare("INSERT OR IGNORE INTO friends(a,b,created_at) VALUES(?,?,?)").run(a, b, now());
      })();
      return res.json({ relationship: "friends" });
    }
    if (countSince(db, "SELECT COUNT(*) n FROM friend_requests WHERE from_id=? AND created_at>?", me, now() - 3600e3) >= LIMITS.requestsPerHour)
      throw fail(429, "That's a lot of requests. Try again later.");
    db.prepare("INSERT OR IGNORE INTO friend_requests(from_id,to_id,created_at) VALUES(?,?,?)").run(me, them, now());
    res.json({ relationship: "requested" });
  });
  // Cancel your request, decline theirs, or unfriend.
  router.delete("/users/:handle/friend", signedIn, (req, res) => {
    const me = req.viewer.id, them = target(req).user_id, [a, b] = pair(me, them);
    db.prepare("DELETE FROM friend_requests WHERE (from_id=? AND to_id=?) OR (from_id=? AND to_id=?)").run(me, them, them, me);
    db.prepare("DELETE FROM friends WHERE a=? AND b=?").run(a, b);
    res.json({ relationship: "none" });
  });

  // --- blocking ------------------------------------------------------------------
  router.get("/blocks", signedIn, (req, res) => {
    res.json({ blocked: db.prepare("SELECT p.* FROM blocks b JOIN profiles p ON p.user_id=b.blocked_id WHERE b.user_id=? ORDER BY b.created_at DESC")
      .all(req.viewer.id).map(publicProfile) });
  });
  // Blocking ends any friendship and pending request, and hides each from the
  // other: comments, profiles, search, friend requests and shares.
  const block = (me, them) => {
    const [a, b] = pair(me, them);
    db.transaction(() => {
      db.prepare("INSERT OR IGNORE INTO blocks(user_id,blocked_id,created_at) VALUES(?,?,?)").run(me, them, now());
      db.prepare("DELETE FROM friends WHERE a=? AND b=?").run(a, b);
      db.prepare("DELETE FROM friend_requests WHERE (from_id=? AND to_id=?) OR (from_id=? AND to_id=?)").run(me, them, them, me);
    })();
  };
  router.post("/users/:handle/block", signedIn, (req, res) => {
    const them = profileByHandle(db, req.params.handle)?.user_id;
    if (!them || them === req.viewer.id) throw fail(404, "No one by that name");
    block(req.viewer.id, them);
    res.json({ relationship: "blocked" });
  });
  router.delete("/users/:handle/block", signedIn, (req, res) => {
    const them = profileByHandle(db, req.params.handle)?.user_id;
    if (them) db.prepare("DELETE FROM blocks WHERE user_id=? AND blocked_id=?").run(req.viewer.id, them);
    res.json({ relationship: "none" });
  });
  router.post("/comments/:id/block", signedIn, (req, res) => {
    const c = db.prepare("SELECT user_id FROM comments WHERE id=?").get(req.params.id);
    if (!c?.user_id || c.user_id === req.viewer.id) throw fail(404, "Comment not found");
    block(req.viewer.id, c.user_id);
    res.json({ blocked: true });
  });

  // --- reporting -----------------------------------------------------------------
  const report = (req, kind, targetID, evidence) => {
    const me = req.viewer.id;
    if (countSince(db, "SELECT COUNT(*) n FROM reports WHERE reporter_id=? AND created_at>?", me, now() - 3600e3) >= LIMITS.reportsPerHour)
      throw fail(429, "Thanks. We've got your reports; we'll look at them shortly.");
    const reason = typeof req.body?.reason === "string" ? req.body.reason.slice(0, LIMITS.reason) : null;
    db.prepare("INSERT INTO reports(id,reporter_id,kind,target_id,reason,evidence,created_at) VALUES(?,?,?,?,?,?,?)")
      .run(newID(), me, kind, targetID, reason, evidence ?? null, now());
  };
  // A reported comment disappears for everyone but its author and the owner
  // until the owner has looked at it.
  router.post("/comments/:id/report", signedIn, (req, res) => {
    const c = db.prepare("SELECT id,user_id FROM comments WHERE id=? AND deleted_at IS NULL").get(req.params.id);
    if (!c) throw fail(404, "Comment not found");
    if (c.user_id === req.viewer.id) throw fail(400, "You can delete your own comment instead");
    report(req, "comment", c.id);
    db.prepare("UPDATE comments SET hidden_at=COALESCE(hidden_at,?) WHERE id=?").run(now(), c.id);
    res.json({ reported: true });
  });
  router.post("/users/:handle/report", signedIn, (req, res) => {
    const p = profileByHandle(db, req.params.handle);
    if (!p || p.user_id === req.viewer.id) throw fail(404, "No one by that name");
    report(req, "user", p.user_id);
    res.json({ reported: true });
  });
  router.post("/shares/:id/report", signedIn, (req, res) => {
    const s = db.prepare("SELECT id FROM shares WHERE id=? AND to_id=?").get(req.params.id, req.viewer.id);
    if (!s) throw fail(404, "Share not found");
    // The server can't read the share, so the reporter's device sends the one
    // message it decrypted, and the report prompt says so.
    const m = req.body?.message;
    const evidence = m && typeof m === "object"
      ? JSON.stringify({ product_id: String(m.product_id ?? "").slice(0, 160), note: String(m.note ?? "").slice(0, LIMITS.note) })
      : null;
    report(req, "share", s.id, evidence);
    res.json({ reported: true });
  });

  // --- comments ------------------------------------------------------------------
  const productID = (req) => {
    const id = String(req.params.id || "");
    if (!/^[\w.-]{1,160}$/.test(id)) throw fail(404, "Product not found");
    return id;
  };
  router.get("/products/:id/comments", (req, res) => {
    const owner = isOwner(req);
    res.json({
      comments: threadsFor(db, productID(req), req.viewer, owner),
      viewer: { signed_in: !!req.viewer, agreed_terms: req.viewer ? agreed(req.viewer.id) : false, owner },
    });
  });
  router.post("/products/:id/comments", signedIn, (req, res) => {
    const product = productID(req), me = req.viewer.id;
    needsTerms(req);
    const body = typeof req.body?.body === "string" ? req.body.body.trim() : "";
    if (!body || body.length > LIMITS.comment) throw fail(400, `Comments are 1 to ${LIMITS.comment} characters`);
    const why = refusal(body);
    if (why) throw fail(422, why);
    if (countSince(db, "SELECT COUNT(*) n FROM comments WHERE user_id=? AND created_at>?", me, now() - 600e3) >= LIMITS.commentsPer10Min)
      throw fail(429, "You're commenting quickly. Try again in a few minutes.");
    // One level of replies: a reply to a reply joins the same thread.
    let parent = null;
    if (req.body?.parent_id != null) {
      const p = db.prepare("SELECT id,parent_id,product_id,deleted_at FROM comments WHERE id=?").get(String(req.body.parent_id));
      if (!p || p.product_id !== product) throw fail(404, "That comment is gone");
      parent = p.parent_id ?? p.id;
    }
    ensureProfile(db, req.viewer);
    const id = newID();
    db.prepare("INSERT INTO comments(id,product_id,user_id,parent_id,body,created_at) VALUES(?,?,?,?,?,?)")
      .run(id, product, me, parent, body.replace(/[ --]/g, ""), now());
    res.status(201).json({ id, parent_id: parent, comments: threadsFor(db, product, req.viewer, isOwner(req)) });
  });
  // A like is a person's own mark, so it needs an account but not the
  // community terms (it posts nothing anyone reads). One per person per
  // comment; liking twice is a no-op.
  const likeable = (req) => {
    const c = db.prepare("SELECT id,user_id,product_id,hidden_at,deleted_at FROM comments WHERE id=?").get(String(req.params.id));
    const me = req.viewer.id;
    if (!c || c.deleted_at || (c.hidden_at && c.user_id !== me && !isOwner(req))
      || (c.user_id && c.user_id !== me && blockedEitherWay(db, me, c.user_id))) throw fail(404, "Comment not found");
    return c;
  };
  const likeState = (id, me) => ({
    likes: db.prepare("SELECT COUNT(*) n FROM comment_likes WHERE comment_id=?").get(id).n,
    liked: !!db.prepare("SELECT 1 FROM comment_likes WHERE comment_id=? AND user_id=?").get(id, me),
  });
  router.post("/comments/:id/like", signedIn, (req, res) => {
    const c = likeable(req), me = req.viewer.id;
    if (countSince(db, "SELECT COUNT(*) n FROM comment_likes WHERE user_id=? AND created_at>?", me, now() - 3600e3) >= LIMITS.likesPerHour)
      throw fail(429, "You're liking quickly. Try again in a little while.");
    db.prepare("INSERT OR IGNORE INTO comment_likes(comment_id,user_id,created_at) VALUES(?,?,?)").run(c.id, me, now());
    res.json(likeState(c.id, me));
  });
  router.delete("/comments/:id/like", signedIn, (req, res) => {
    const c = likeable(req), me = req.viewer.id;
    db.prepare("DELETE FROM comment_likes WHERE comment_id=? AND user_id=?").run(c.id, me);
    res.json(likeState(c.id, me));
  });
  router.delete("/comments/:id", signedIn, (req, res) => {
    const c = db.prepare("SELECT * FROM comments WHERE id=?").get(req.params.id);
    if (!c || c.deleted_at) throw fail(404, "Comment not found");
    if (c.user_id !== req.viewer.id && !isOwner(req)) throw fail(403, "That's not your comment");
    db.prepare("UPDATE comments SET body='', deleted_at=? WHERE id=?").run(now(), c.id);
    res.json({ comments: threadsFor(db, c.product_id, req.viewer, isOwner(req)) });
  });

  // --- devices and keys -------------------------------------------------------
  const B64 = /^[A-Za-z0-9+/]+={0,2}$/;
  const bytes = (v, n) => typeof v === "string" && B64.test(v) && Buffer.from(v, "base64").length === n;
  // A P-256 public key as its 65-byte uncompressed point.
  const publicKey = (v) => bytes(v, 65) && Buffer.from(v, "base64")[0] === 4;
  router.post("/devices", signedIn, (req, res) => {
    const key = req.body?.public_key;
    if (!publicKey(key)) throw fail(400, "Invalid device key");
    const me = req.viewer.id, id = newID();
    db.transaction(() => {
      db.prepare("INSERT INTO devices(id,user_id,public_key,created_at,last_seen) VALUES(?,?,?,?,?)").run(id, me, key, now(), now());
      // Ten devices is plenty; the oldest unused one makes room.
      const extra = db.prepare("SELECT id FROM devices WHERE user_id=? ORDER BY last_seen DESC LIMIT -1 OFFSET 10").all(me);
      for (const d of extra) {
        db.prepare("DELETE FROM share_envelopes WHERE device_id=?").run(d.id);
        db.prepare("DELETE FROM devices WHERE id=?").run(d.id);
      }
    })();
    ensureProfile(db, req.viewer);
    res.status(201).json({ device_id: id });
  });
  router.delete("/devices/:id", signedIn, (req, res) => {
    const d = db.prepare("SELECT id FROM devices WHERE id=? AND user_id=?").get(req.params.id, req.viewer.id);
    if (d) db.transaction(() => {
      db.prepare("DELETE FROM share_envelopes WHERE device_id=?").run(d.id);
      db.prepare("DELETE FROM devices WHERE id=?").run(d.id);
    })();
    res.sendStatus(204);
  });
  // Public keys of friends' devices, to seal a share for each. Strangers' keys
  // are never handed out.
  router.get("/keys", signedIn, (req, res) => {
    const me = req.viewer.id;
    const handles = String(req.query.handles || "").split(",").map((h) => h.trim()).filter(Boolean).slice(0, 20);
    const keys = {};
    for (const h of handles) {
      const p = profileByHandle(db, h);
      if (!p || !areFriends(db, me, p.user_id) || blockedEitherWay(db, me, p.user_id)) continue;
      keys[p.handle] = db.prepare("SELECT id AS device_id, public_key FROM devices WHERE user_id=? ORDER BY last_seen DESC").all(p.user_id);
    }
    res.json({ keys });
  });

  // --- sharing -------------------------------------------------------------------
  // { messages: [{ to: handle, envelopes: [{ device_id, ephemeral_key, nonce, ciphertext }] }] }
  router.post("/shares", signedIn, (req, res) => {
    const me = req.viewer.id;
    needsTerms(req);
    const messages = Array.isArray(req.body?.messages) ? req.body.messages.slice(0, 20) : [];
    if (!messages.length) throw fail(400, "Choose who to send it to");
    if (countSince(db, "SELECT COUNT(*) n FROM shares WHERE from_id=? AND created_at>?", me, now() - 600e3) + messages.length > LIMITS.sharesPer10Min)
      throw fail(429, "That's a lot of sharing. Try again in a few minutes.");
    const planned = [];
    for (const m of messages) {
      const p = profileByHandle(db, m?.to);
      if (!p || p.user_id === me || !areFriends(db, me, p.user_id) || blockedEitherWay(db, me, p.user_id))
        throw fail(400, "You can only send products to friends");
      const theirs = new Set(db.prepare("SELECT id FROM devices WHERE user_id=?").all(p.user_id).map((d) => d.id));
      const envelopes = Array.isArray(m.envelopes) ? m.envelopes.slice(0, 10) : [];
      // Every envelope for one of the recipient's own devices, and well formed:
      // a 65-byte ephemeral key, a 12-byte nonce, a bounded ciphertext.
      const ok = envelopes.length && envelopes.every((e) => e && theirs.has(e.device_id) && publicKey(e.ephemeral_key)
        && bytes(e.nonce, 12) && typeof e.ciphertext === "string" && B64.test(e.ciphertext) && e.ciphertext.length <= 4096);
      if (!ok) throw fail(400, `${p.display_name} needs to open Marracat once before they can receive shares`, "no_devices");
      planned.push({ p, envelopes });
    }
    ensureProfile(db, req.viewer);
    const share = db.prepare("INSERT INTO shares(id,from_id,to_id,created_at) VALUES(?,?,?,?)");
    const seal = db.prepare("INSERT INTO share_envelopes(share_id,device_id,ephemeral_key,nonce,ciphertext) VALUES(?,?,?,?,?)");
    db.transaction(() => {
      for (const { p, envelopes } of planned) {
        const id = newID();
        share.run(id, me, p.user_id, now());
        for (const e of envelopes) seal.run(id, e.device_id, e.ephemeral_key, e.nonce, e.ciphertext);
      }
    })();
    res.status(201).json({ sent: planned.map(({ p }) => publicProfile(p)) });
  });
  // The shares sent to you, each with the envelope sealed for the device
  // asking. A device added after a share was sent has none for it.
  router.get("/shares", signedIn, (req, res) => {
    const me = req.viewer.id;
    const device = db.prepare("SELECT id FROM devices WHERE id=? AND user_id=?").get(String(req.query.device || ""), me);
    if (device) db.prepare("UPDATE devices SET last_seen=? WHERE id=?").run(now(), device.id);
    const blocked = blockedSet(db, me);
    const rows = db.prepare(`SELECT s.*, p.handle, p.display_name, e.ephemeral_key, e.nonce, e.ciphertext
      FROM shares s JOIN profiles p ON p.user_id=s.from_id
      LEFT JOIN share_envelopes e ON e.share_id=s.id AND e.device_id=?
      WHERE s.to_id=? ORDER BY s.created_at DESC LIMIT 100`).all(device?.id ?? "", me).filter((s) => !blocked.has(s.from_id));
    res.json({
      // False when this device's key is gone from the server (retired, or the
      // oldest of more than ten): the client makes a new one and asks again,
      // rather than silently getting nothing it can open from now on.
      device_known: !!device,
      shares: rows.map((s) => ({
        id: s.id, from: { handle: s.handle, name: s.display_name }, created_at: s.created_at, seen: !!s.seen_at,
        envelope: s.ciphertext ? { ephemeral_key: s.ephemeral_key, nonce: s.nonce, ciphertext: s.ciphertext } : null,
      })),
    });
  });
  router.post("/shares/seen", signedIn, (req, res) => {
    db.prepare("UPDATE shares SET seen_at=? WHERE to_id=? AND seen_at IS NULL").run(now(), req.viewer.id);
    res.json({ ok: true });
  });

  // --- moderation (owner only) ---------------------------------------------------
  const ownerOnly = (req, res, next) => (isOwner(req) ? next() : res.status(404).json({ error: "Not found" }));
  router.get("/moderation", signedIn, ownerOnly, (req, res) => {
    const open = db.prepare("SELECT * FROM reports WHERE resolved_at IS NULL ORDER BY created_at ASC LIMIT 200").all();
    res.json({ reports: open.map((r) => {
      let subject = null;
      if (r.kind === "comment") {
        const c = db.prepare("SELECT c.*, p.handle, p.display_name FROM comments c LEFT JOIN profiles p ON p.user_id=c.user_id WHERE c.id=?").get(r.target_id);
        subject = c && { product_id: c.product_id, body: c.body, author: c.handle ? { handle: c.handle, name: c.display_name } : null, deleted: !!c.deleted_at };
      } else if (r.kind === "user") {
        subject = publicProfile(db.prepare("SELECT * FROM profiles WHERE user_id=?").get(r.target_id));
      } else if (r.kind === "share") {
        const s = db.prepare("SELECT s.*, p.handle, p.display_name FROM shares s LEFT JOIN profiles p ON p.user_id=s.from_id WHERE s.id=?").get(r.target_id);
        // Only what the reporter's device decrypted and chose to send.
        const shown = r.evidence ? JSON.parse(r.evidence) : {};
        subject = s && { product_id: shown.product_id ?? null, note: shown.note ?? null,
          author: s.handle ? { handle: s.handle, name: s.display_name } : null };
      }
      return { id: r.id, kind: r.kind, reason: r.reason, created_at: r.created_at, subject };
    }) });
  });
  // restore: the report was wrong, show it again. remove: take the content
  // down. suspend: take it down and stop the author posting at all.
  router.post("/moderation/:id", signedIn, ownerOnly, (req, res) => {
    const r = db.prepare("SELECT * FROM reports WHERE id=?").get(req.params.id);
    const action = req.body?.action;
    if (!r) throw fail(404, "Report not found");
    if (!["restore", "remove", "suspend"].includes(action)) throw fail(400, "Choose restore, remove or suspend");
    db.transaction(() => {
      let author = null;
      if (r.kind === "comment") {
        author = db.prepare("SELECT user_id FROM comments WHERE id=?").get(r.target_id)?.user_id;
        if (action === "restore") db.prepare("UPDATE comments SET hidden_at=NULL WHERE id=?").run(r.target_id);
        else db.prepare("UPDATE comments SET body='', deleted_at=? WHERE id=?").run(now(), r.target_id);
      } else if (r.kind === "share") {
        author = db.prepare("SELECT from_id FROM shares WHERE id=?").get(r.target_id)?.from_id;
        if (action !== "restore") {
          db.prepare("DELETE FROM share_envelopes WHERE share_id=?").run(r.target_id);
          db.prepare("DELETE FROM shares WHERE id=?").run(r.target_id);
        }
      } else if (r.kind === "user") author = r.target_id;
      if (action === "suspend" && author)
        db.prepare("INSERT INTO user_flags(user_id,suspended_at) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET suspended_at=excluded.suspended_at").run(author, now());
      db.prepare("UPDATE reports SET resolved_at=?, resolution=? WHERE kind=? AND target_id=? AND resolved_at IS NULL").run(now(), action, r.kind, r.target_id);
    })();
    res.json({ ok: true });
  });

  router.use((error, req, res, next) => {
    const status = [400, 401, 403, 404, 409, 422, 428, 429].includes(error.status) ? error.status
      : error.type === "entity.parse.failed" ? 400 : error.type === "entity.too.large" ? 413 : 500;
    if (status === 500) console.error("Social request failed:", error.name);
    res.status(status).json({ error: status === 500 ? "That didn't work. Try again." : error.message, ...(error.code ? { code: error.code } : {}) });
  });
  app.use("/api/social", router);
}
