import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { accountFor, installIdentitySchema } from "../server/identities.js";
import { deletePasskeyData, deviceName, installPasskeySchema, loginOptions, passkeyRoutes, registrationOptions, relyingParty, verifyAssertion, verifyRegistration, CHALLENGE_TTL, MAX_PER_USER } from "../server/passkeys.js";

// Passkeys (owner, 2026-11-10). A stand-in authenticator below makes real
// keys and signs exactly what WebAuthn signs, so every check runs for real.
const RP = { id: "marracat.com", name: "Marracat", origins: ["https://marracat.com"] };
const sha256 = (d) => createHash("sha256").update(d).digest();
const b64u = (b) => Buffer.from(b).toString("base64url");

function authenticator(kind = "ec") {
  const { publicKey, privateKey } = kind === "ec" ? generateKeyPairSync("ec", { namedCurve: "P-256" })
    : kind === "ed25519" ? generateKeyPairSync("ed25519") : generateKeyPairSync("rsa", { modulusLength: 2048 });
  const alg = kind === "ec" ? -7 : kind === "ed25519" ? -8 : -257;
  const id = randomBytes(32);
  let counter = 0;
  const data = ({ rpID = RP.id, flags = 0x05, attested = false, count = counter }) => {
    const head = Buffer.alloc(37);
    sha256(rpID).copy(head, 0);
    head[32] = flags | (attested ? 0x40 : 0);
    head.writeUInt32BE(count, 33);
    if (!attested) return head;
    const len = Buffer.alloc(2);
    len.writeUInt16BE(id.length);
    return Buffer.concat([head, Buffer.alloc(16), len, id, Buffer.from([0xa5])]); // COSE key: not read
  };
  const client = (type, challenge, origin = RP.origins[0], extra = {}) => Buffer.from(JSON.stringify({ type, challenge, origin, crossOrigin: false, ...extra }));
  return {
    id: b64u(id),
    create(challenge, over = {}) {
      return {
        id: b64u(over.credentialId ?? id),
        clientDataJSON: b64u(client(over.type ?? "webauthn.create", challenge, over.origin)),
        authenticatorData: b64u(data({ rpID: over.rpID, flags: over.flags, attested: over.attested ?? true })),
        publicKey: b64u(publicKey.export({ format: "der", type: "spki" })),
        publicKeyAlgorithm: over.alg ?? alg,
        transports: ["internal", "hybrid", "<bad>"],
      };
    },
    get(challenge, over = {}) {
      if (over.count === undefined && over.counting) counter++;
      const authData = data({ rpID: over.rpID, flags: over.flags, count: over.count ?? counter });
      const clientDataJSON = client(over.type ?? "webauthn.get", challenge, over.origin);
      const signed = Buffer.concat([authData, sha256(clientDataJSON)]);
      const signature = kind === "ed25519" ? sign(null, signed, privateKey) : sign("sha256", signed, privateKey);
      return { id: b64u(id), clientDataJSON: b64u(clientDataJSON), authenticatorData: b64u(authData), signature: b64u(over.tamper ? Buffer.concat([signature.subarray(0, -1), Buffer.from([signature.at(-1) ^ 1])]) : signature) };
    },
  };
}
const fresh = () => {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT)");
  db.prepare("INSERT INTO users VALUES ('google:ada','Ada','ada@example.test'),('google:bo','Bo','bo@example.test')").run();
  installPasskeySchema(db);
  return db;
};
const ada = { id: "google:ada", name: "Ada", email: "ada@example.test" };

test("a passkey of each kind is added, then signs in to its own account", () => {
  for (const kind of ["ec", "ed25519", "rsa"]) {
    const db = fresh(), key = authenticator(kind);
    const opts = registrationOptions(db, ada, RP);
    assert.equal(opts.rp.id, "marracat.com");
    assert.equal(opts.authenticatorSelection.userVerification, "required");
    assert.doesNotMatch(opts.user.id, /ada|google/, "the handle on the device says nothing about the account");
    assert.deepEqual(verifyRegistration(db, key.create(opts.challenge), { user: ada, rp: RP }), { id: key.id }, kind);
    assert.deepEqual(JSON.parse(db.prepare("SELECT transports FROM passkeys").get().transports), ["internal", "hybrid"]);
    const id = verifyAssertion(db, key.get(loginOptions(db, RP).challenge), { rp: RP });
    assert.equal(id, key.id, kind);
    // That identity opens Ada's account, as Google and email sign-ins do.
    assert.equal(accountFor(db, { id: "passkey:" + id, email: null, emailVerified: false }), "google:ada");
    assert.ok(db.prepare("SELECT last_used FROM passkeys").get().last_used);
  }
});

test("a sign-in fails on any wrong detail, and a challenge works once", () => {
  const db = fresh(), key = authenticator();
  verifyRegistration(db, key.create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP });
  const tries = {
    "another site's origin": { origin: "https://evil.example" },
    "another site's domain": { rpID: "evil.example" },
    "a registration, not a sign-in": { type: "webauthn.create" },
    "no face, finger or PIN": { flags: 0x01 },
    "nobody present": { flags: 0x04 },
    "a changed signature": { tamper: true },
  };
  for (const [why, over] of Object.entries(tries)) assert.equal(verifyAssertion(db, key.get(loginOptions(db, RP).challenge, over), { rp: RP }), null, why);
  assert.equal(verifyAssertion(db, key.get(b64u(randomBytes(32))), { rp: RP }), null, "a challenge we never gave");
  const challenge = loginOptions(db, RP).challenge;
  assert.ok(verifyAssertion(db, key.get(challenge), { rp: RP }));
  assert.equal(verifyAssertion(db, key.get(challenge), { rp: RP }), null, "replayed");
  const old = loginOptions(db, RP, Date.now() - CHALLENGE_TTL - 1000).challenge;
  assert.equal(verifyAssertion(db, key.get(old), { rp: RP }), null, "expired");
  const other = authenticator();
  assert.equal(verifyAssertion(db, other.get(loginOptions(db, RP).challenge), { rp: RP }), null, "a key we don't know");
  for (const junk of [null, {}, { id: "x" }, { ...key.get(loginOptions(db, RP).challenge), signature: "%%%" }]) assert.equal(verifyAssertion(db, junk, { rp: RP }), null);
});

test("a counter that goes backwards means a copied key, and is refused", () => {
  const db = fresh(), key = authenticator();
  verifyRegistration(db, key.create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP });
  assert.ok(verifyAssertion(db, key.get(loginOptions(db, RP).challenge, { count: 5 }), { rp: RP }));
  assert.equal(verifyAssertion(db, key.get(loginOptions(db, RP).challenge, { count: 5 }), { rp: RP }), null);
  assert.ok(verifyAssertion(db, key.get(loginOptions(db, RP).challenge, { count: 6 }), { rp: RP }));
  // Synced passkeys always say 0, and that is fine.
  const synced = authenticator();
  verifyRegistration(db, synced.create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP });
  for (let i = 0; i < 2; i++) assert.ok(verifyAssertion(db, synced.get(loginOptions(db, RP).challenge, { count: 0 }), { rp: RP }));
});

test("adding a passkey is checked as carefully, and only for the account that asked", () => {
  const db = fresh(), key = authenticator();
  const bo = { id: "google:bo", name: "Bo" };
  // A challenge given to Ada can't add a passkey to Bo's account, or the other way round.
  assert.equal(verifyRegistration(db, key.create(registrationOptions(db, ada, RP).challenge), { user: bo, rp: RP }).error, "ceremony");
  assert.equal(verifyRegistration(db, key.create(loginOptions(db, RP).challenge), { user: ada, rp: RP }).error, "ceremony", "a sign-in challenge");
  const bad = {
    ceremony: [{ origin: "https://evil.example" }, { rpID: "evil.example" }, { type: "webauthn.get" }, { flags: 0x01 }],
    "no credential": [{ attested: false }],
    "credential mismatch": [{ credentialId: randomBytes(32) }],
    key: [{ alg: -257 }],
    incomplete: [{ alg: -999 }],
  };
  for (const [error, overs] of Object.entries(bad)) for (const over of overs)
    assert.equal(verifyRegistration(db, key.create(registrationOptions(db, ada, RP).challenge, over), { user: ada, rp: RP }).error, error, JSON.stringify(over));
  assert.ok(verifyRegistration(db, key.create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP }).id);
  assert.equal(verifyRegistration(db, key.create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP }).error, "exists");
  assert.deepEqual(registrationOptions(db, ada, RP).excludeCredentials.map((c) => c.id), [key.id], "the device is told not to make a second one");
  for (let i = 1; i < MAX_PER_USER; i++) verifyRegistration(db, authenticator().create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP });
  assert.equal(verifyRegistration(db, authenticator().create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP }).error, "limit");
});

test("deleting the account deletes its passkeys and their links; other accounts keep theirs", () => {
  const db = fresh(), mine = authenticator(), theirs = authenticator();
  verifyRegistration(db, mine.create(registrationOptions(db, ada, RP).challenge), { user: ada, rp: RP });
  verifyRegistration(db, theirs.create(registrationOptions(db, { id: "google:bo" }, RP).challenge), { user: { id: "google:bo" }, rp: RP });
  deletePasskeyData(db, "google:ada");
  assert.equal(verifyAssertion(db, mine.get(loginOptions(db, RP).challenge), { rp: RP }), null);
  assert.deepEqual(db.prepare("SELECT identity FROM user_identities").all().map((r) => r.identity), ["passkey:" + theirs.id]);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM passkey_handles").get().n, 1);
});

test("where passkeys belong: marracat.com live, localhost on a Mac", () => {
  assert.deepEqual(relyingParty({ NODE_ENV: "production" }), RP);
  assert.deepEqual(relyingParty({ PORT: "4000" }).origins, ["http://localhost:4000"]);
  assert.equal(deviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 Version/19.0 Mobile/15E148 Safari/604.1"), "Safari on iPhone");
  assert.equal(deviceName("Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/140 Safari/537.36 Edg/140"), "Edge on Windows");
  assert.equal(deviceName(""), "This device");
});

test("/api/passkeys: sign-in options for anyone; adding, listing and removing only for the signed-in account", async () => {
  const db = fresh(), key = authenticator();
  let user = null;
  const app = express();
  passkeyRoutes(app, db, { viewer: async () => user, rp: RP });
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api/passkeys`;
  const call = async (path, method = "POST", body) => fetch(base + path, { method, headers: { "Content-Type": "application/json", "User-Agent": "Mozilla/5.0 (Macintosh; Mac OS X) Safari/605" }, body: body && JSON.stringify(body) });
  try {
    assert.equal((await (await call("/login/options")).json()).rpId, "marracat.com");
    assert.equal((await call("/register/options")).status, 401);
    assert.equal((await call("/", "GET")).status, 401);
    user = ada;
    const opts = await (await call("/register/options")).json();
    assert.equal((await call("/register", "POST", key.create(opts.challenge))).status, 200);
    assert.equal((await call("/register", "POST", key.create((await (await call("/register/options")).json()).challenge))).status, 409);
    assert.equal((await call("/register", "POST", { id: "x" })).status, 400);
    const list = (await (await call("/", "GET")).json()).passkeys;
    assert.deepEqual(list.map((p) => [p.id, p.name]), [[key.id, "Safari on Mac"]]);
    // Bo can't remove Ada's passkey.
    user = { id: "google:bo" };
    assert.equal((await (await call("/" + key.id, "DELETE")).json()).removed, 0);
    assert.equal(db.prepare("SELECT COUNT(*) n FROM sqlite_master WHERE name='web_session_cutoffs'").get().n, 0, "a refused removal ends nobody's session");
    user = { ...ada, sid: "a".repeat(32) };
    assert.equal((await (await call("/" + key.id, "DELETE")).json()).removed, 1);
    assert.equal(db.prepare("SELECT COUNT(*) n FROM user_identities WHERE identity LIKE 'passkey:%'").get().n, 0);
    // 2026-11-12: sessions opened with the removed passkey used to live on.
    const cut = db.prepare("SELECT user_id, keep_sid, after FROM web_session_cutoffs").get();
    assert.equal(cut.user_id, ada.id);
    assert.equal(cut.keep_sid, "a".repeat(32), "the browser that removed it stays signed in");
    assert.ok(cut.after > 0);
  } finally {
    server.close();
  }
});
