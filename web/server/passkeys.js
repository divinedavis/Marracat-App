// Passkeys on marracat.com (owner, 2026-11-10: "lets do passkeys"). A
// signed-in shopper adds one on the account page; afterwards "Sign in with a
// passkey" opens the same account with Face ID, Touch ID, Windows Hello or a
// phone, and no password or code.
//
// The WebAuthn checks are node:crypto, as the spec lays them out (W3C WebAuthn
// Level 3, sections 7.1 and 7.2). Attestation is "none": we don't ask which
// device made the key, only that the same key signs later. The browser hands
// over the new public key itself (AuthenticatorAttestationResponse
// .getPublicKey(), in every current browser), so no CBOR is read here.
//
// A passkey is an identity linked to its account (user_identities, as
// identities.js does for Google, Apple and email), "passkey:<credential id>",
// so Auth.js opens that account through a Credentials provider (auth.js).
import { revokeOtherSessions } from "./web-sessions.js";
import express from "express";
import { createHash, createPublicKey, randomBytes, verify } from "node:crypto";
import { rateLimit } from "express-rate-limit";
import { installIdentitySchema } from "./identities.js";

const sha256 = (data) => createHash("sha256").update(data).digest();
const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const B64U = /^[A-Za-z0-9_-]+$/;
const bytes = (value, max) => (typeof value === "string" && value.length <= max && B64U.test(value) ? Buffer.from(value, "base64url") : null);

export const CHALLENGE_TTL = 5 * 60_000;
export const MAX_PER_USER = 10;
// ES256, EdDSA and RS256: what browsers and authenticators make.
const ALGS = { [-7]: "ec", [-8]: "ed25519", [-257]: "rsa" };
const FLAG_UP = 0x01, FLAG_UV = 0x04, FLAG_AT = 0x40;

/// Where passkeys belong: marracat.com when live; localhost otherwise (an IP
/// address can't hold a passkey, so local tests use http://localhost).
export function relyingParty(env = process.env) {
  if (env.NODE_ENV === "production") return { id: "marracat.com", name: "Marracat", origins: ["https://marracat.com"] };
  const port = env.PORT || 3107;
  return { id: "localhost", name: "Marracat", origins: [`http://localhost:${port}`] };
}

export function installPasskeySchema(db) {
  installIdentitySchema(db);
  db.exec(`
    CREATE TABLE IF NOT EXISTS passkeys (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL, public_key TEXT NOT NULL, alg INTEGER NOT NULL,
      counter INTEGER NOT NULL DEFAULT 0, transports TEXT, name TEXT, created INTEGER NOT NULL, last_used INTEGER);
    CREATE INDEX IF NOT EXISTS passkeys_user ON passkeys(user_id);
    CREATE TABLE IF NOT EXISTS passkey_challenges (
      hash TEXT PRIMARY KEY, purpose TEXT NOT NULL, user_id TEXT, expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS passkey_handles (user_id TEXT PRIMARY KEY, handle TEXT NOT NULL UNIQUE);`);
}

export function deletePasskeyData(db, userID) {
  db.prepare("DELETE FROM passkeys WHERE user_id=?").run(userID);
  db.prepare("DELETE FROM passkey_handles WHERE user_id=?").run(userID);
  db.prepare("DELETE FROM user_identities WHERE user_id=? AND identity LIKE 'passkey:%'").run(userID);
}

/// A one-use challenge for "register" (tied to the account) or "login".
export function newChallenge(db, purpose, userID = null, now = Date.now()) {
  db.prepare("DELETE FROM passkey_challenges WHERE expires < ?").run(now);
  const challenge = randomBytes(32);
  db.prepare("INSERT INTO passkey_challenges(hash,purpose,user_id,expires) VALUES(?,?,?,?)").run(sha256(challenge).toString("hex"), purpose, userID, now + CHALLENGE_TTL);
  return b64u(challenge);
}
/// Spends a challenge; true only once, in time, for that purpose and account.
function spendChallenge(db, challenge, purpose, userID, now) {
  const key = sha256(Buffer.from(challenge, "base64url")).toString("hex");
  const row = db.prepare("SELECT purpose, user_id, expires FROM passkey_challenges WHERE hash=?").get(key);
  if (!row) return false;
  db.prepare("DELETE FROM passkey_challenges WHERE hash=?").run(key);
  return row.purpose === purpose && row.expires >= now && (purpose !== "register" || row.user_id === userID);
}

/// The random, meaningless id the authenticator stores for the account
/// (WebAuthn's user.id must not be an email or account id).
function userHandle(db, userID) {
  let row = db.prepare("SELECT handle FROM passkey_handles WHERE user_id=?").get(userID);
  if (!row) {
    row = { handle: b64u(randomBytes(16)) };
    db.prepare("INSERT INTO passkey_handles(user_id,handle) VALUES(?,?)").run(userID, row.handle);
  }
  return row.handle;
}

/// What navigator.credentials.create() needs, for a signed-in account.
export function registrationOptions(db, user, rp = relyingParty(), now = Date.now()) {
  installPasskeySchema(db);
  return {
    challenge: newChallenge(db, "register", user.id, now),
    rp: { id: rp.id, name: rp.name },
    user: { id: userHandle(db, user.id), name: user.email || user.name || "Marracat shopper", displayName: user.name || user.email || "Marracat shopper" },
    pubKeyCredParams: Object.keys(ALGS).map((alg) => ({ type: "public-key", alg: Number(alg) })),
    timeout: CHALLENGE_TTL,
    attestation: "none",
    authenticatorSelection: { residentKey: "required", requireResidentKey: true, userVerification: "required" },
    excludeCredentials: db.prepare("SELECT id, transports FROM passkeys WHERE user_id=?").all(user.id)
      .map((r) => ({ type: "public-key", id: r.id, transports: JSON.parse(r.transports || "[]") })),
  };
}

/// What navigator.credentials.get() needs to sign in. No account is named:
/// the device offers the passkeys it holds for marracat.com.
export function loginOptions(db, rp = relyingParty(), now = Date.now()) {
  installPasskeySchema(db);
  return { challenge: newChallenge(db, "login", null, now), rpId: rp.id, timeout: CHALLENGE_TTL, userVerification: "required" };
}

/// The checks both ceremonies share: clientDataJSON says this ceremony, our
/// challenge and our origin; authenticatorData is for our domain, with the
/// person present and verified (face, fingerprint or PIN).
function checkCeremony(db, { clientDataJSON, authenticatorData }, { type, purpose, userID, rp, now }) {
  let client;
  try {
    client = JSON.parse(clientDataJSON.toString("utf8"));
  } catch {
    return null;
  }
  if (client?.type !== type || typeof client.challenge !== "string" || !B64U.test(client.challenge)) return null;
  if (!rp.origins.includes(client.origin) || client.crossOrigin === true) return null;
  if (!spendChallenge(db, client.challenge, purpose, userID, now)) return null;
  if (authenticatorData.length < 37 || !authenticatorData.subarray(0, 32).equals(sha256(rp.id))) return null;
  const flags = authenticatorData[32];
  if (!(flags & FLAG_UP) || !(flags & FLAG_UV)) return null;
  return { flags, counter: authenticatorData.readUInt32BE(33) };
}

/// Checks a new passkey and keeps it for the account. Returns its row, or
/// null and a reason.
export function verifyRegistration(db, body, { user, rp = relyingParty(), now = Date.now(), name = null }) {
  installPasskeySchema(db);
  const id = bytes(body?.id, 1400), clientDataJSON = bytes(body?.clientDataJSON, 4000), authenticatorData = bytes(body?.authenticatorData, 4000);
  const spki = bytes(body?.publicKey, 2000), alg = body?.publicKeyAlgorithm;
  if (!id || !id.length || !clientDataJSON || !authenticatorData || !spki || !ALGS[alg]) return { error: "incomplete" };
  const ceremony = checkCeremony(db, { clientDataJSON, authenticatorData }, { type: "webauthn.create", purpose: "register", userID: user.id, rp, now });
  if (!ceremony) return { error: "ceremony" };
  // The credential in authenticatorData is the one we were told about.
  if (!(ceremony.flags & FLAG_AT) || authenticatorData.length < 55) return { error: "no credential" };
  const idLength = authenticatorData.readUInt16BE(53);
  if (!authenticatorData.subarray(55, 55 + idLength).equals(id)) return { error: "credential mismatch" };
  let key;
  try {
    key = createPublicKey({ key: spki, format: "der", type: "spki" });
  } catch {
    return { error: "key" };
  }
  const kind = key.asymmetricKeyType;
  if (kind !== ALGS[alg] || (kind === "ec" && key.asymmetricKeyDetails?.namedCurve !== "prime256v1")) return { error: "key" };
  const credentialID = b64u(id);
  if (db.prepare("SELECT 1 FROM passkeys WHERE id=?").get(credentialID)) return { error: "exists" };
  if (db.prepare("SELECT COUNT(*) n FROM passkeys WHERE user_id=?").get(user.id).n >= MAX_PER_USER) return { error: "limit" };
  const transports = Array.isArray(body.transports) ? body.transports.filter((t) => /^[a-z-]{2,16}$/.test(t)).slice(0, 6) : [];
  db.transaction(() => {
    db.prepare("INSERT INTO passkeys(id,user_id,public_key,alg,counter,transports,name,created) VALUES(?,?,?,?,?,?,?,?)")
      .run(credentialID, user.id, b64u(spki), alg, ceremony.counter, JSON.stringify(transports), name, now);
    db.prepare("INSERT INTO user_identities(identity,user_id,linked) VALUES(?,?,?) ON CONFLICT(identity) DO UPDATE SET user_id=excluded.user_id")
      .run("passkey:" + credentialID, user.id, now);
  })();
  return { id: credentialID };
}

/// Checks a sign-in with a passkey. Returns the credential id (the identity
/// Auth.js links to its account), or null.
export function verifyAssertion(db, body, { rp = relyingParty(), now = Date.now() } = {}) {
  installPasskeySchema(db);
  const id = typeof body?.id === "string" && body.id.length <= 1400 && B64U.test(body.id) ? body.id : null;
  const clientDataJSON = bytes(body?.clientDataJSON, 4000), authenticatorData = bytes(body?.authenticatorData, 4000), signature = bytes(body?.signature, 1200);
  if (!id || !clientDataJSON || !authenticatorData || !signature) return null;
  const row = db.prepare("SELECT id, user_id, public_key, alg, counter FROM passkeys WHERE id=?").get(id);
  if (!row) return null;
  const ceremony = checkCeremony(db, { clientDataJSON, authenticatorData }, { type: "webauthn.get", purpose: "login", userID: null, rp, now });
  if (!ceremony) return null;
  const key = createPublicKey({ key: Buffer.from(row.public_key, "base64url"), format: "der", type: "spki" });
  const signed = Buffer.concat([authenticatorData, sha256(clientDataJSON)]);
  let ok = false;
  try {
    ok = row.alg === -8 ? verify(null, signed, key, signature) : verify("sha256", signed, row.alg === -7 ? { key, dsaEncoding: "der" } : key, signature);
  } catch {
    ok = false;
  }
  if (!ok) return null;
  // A counter that went backwards means a copied key (WebAuthn 6.1.1); most
  // passkeys sync between devices and always report 0.
  if (ceremony.counter && row.counter && ceremony.counter <= row.counter) return null;
  db.prepare("UPDATE passkeys SET counter=?, last_used=? WHERE id=?").run(ceremony.counter, now, id);
  // The link that opens the account; restored if it was ever lost.
  db.prepare("INSERT INTO user_identities(identity,user_id,linked) VALUES(?,?,?) ON CONFLICT(identity) DO UPDATE SET user_id=excluded.user_id")
    .run("passkey:" + id, row.user_id, now);
  return id;
}

/// A short name for the account page: which kind of device it was added from.
export function deviceName(userAgent = "") {
  const ua = String(userAgent);
  const os = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) ? "iPad" : /Android/.test(ua) ? "Android" : /Mac OS X|Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /CrOS/.test(ua) ? "Chromebook" : /Linux/.test(ua) ? "Linux" : "";
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "";
  return [browser, os].filter(Boolean).join(" on ") || "This device";
}

export function passkeyRoutes(app, db, { viewer, rp = relyingParty() }) {
  installPasskeySchema(db);
  const router = express.Router();
  router.use((req, res, next) => { res.set("Cache-Control", "no-store"); next(); });
  router.use(rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: "draft-8", legacyHeaders: false }));
  router.use(express.json({ limit: "16kb" }));
  router.post("/login/options", (req, res) => res.json(loginOptions(db, rp)));
  router.use(async (req, res, next) => {
    req.user = await viewer(req).catch(() => null);
    if (!req.user) return res.status(401).json({ error: "Sign in to add a passkey" });
    next();
  });
  router.get("/", (req, res) => res.json({
    passkeys: db.prepare("SELECT id, name, created, last_used AS lastUsed FROM passkeys WHERE user_id=? ORDER BY created").all(req.user.id),
  }));
  router.post("/register/options", (req, res) => res.json(registrationOptions(db, req.user, rp)));
  router.post("/register", (req, res) => {
    const result = verifyRegistration(db, req.body, { user: req.user, rp, name: deviceName(req.get("User-Agent")) });
    if (result.error === "exists") return res.status(409).json({ error: "That passkey is already on your account" });
    if (result.error === "limit") return res.status(409).json({ error: `An account can have ${MAX_PER_USER} passkeys. Remove one first.` });
    if (result.error) return res.status(400).json({ error: "That passkey couldn't be added. Please try again." });
    res.json({ ok: true, id: result.id });
  });
  router.delete("/:id", (req, res) => {
    const id = req.params.id;
    const gone = db.prepare("DELETE FROM passkeys WHERE id=? AND user_id=?").run(id, req.user.id).changes;
    if (gone) {
      db.prepare("DELETE FROM user_identities WHERE identity=? AND user_id=?").run("passkey:" + id, req.user.id);
      // Whoever was signed in with that passkey, or anything else, is signed
      // out; the browser removing it stays in (web-sessions.js).
      revokeOtherSessions(db, req.user.id, req.user.sid);
    }
    res.json({ ok: true, removed: gone });
  });
  app.use("/api/passkeys", router);
}
