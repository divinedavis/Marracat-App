import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { createECDH, createDecipheriv, createHmac, createPublicKey, verify } from "node:crypto";
import { encrypt, generateKeys, vapidHeader, pushEndpoint, webPushSender, webPushRoutes, noteFromAPNs, installWebPushSchema, deleteWebPushData, MAX_PAYLOAD } from "../server/web-push.js";

// Browser notifications (owner, 2026-11-10). The encryption is our own page
// of node:crypto, so it is held to RFC 8291's worked example, byte for byte.
const RFC = {
  plaintext: "When I grow up, I want to be a watermelon",
  auth: "BTBZMqHH6r4Tts7J_aSIgg", // gitleaks:allow (RFC 8291 section 5 published example, not a key)
  uaPrivate: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94",
  uaPublic: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
  asPrivate: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
  salt: "DGv6ra1nlYgDCS1FRnbzlw",
  message: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
};

test("the encrypted message is RFC 8291's own example, byte for byte", () => {
  const sealed = encrypt(RFC.plaintext, { p256dh: RFC.uaPublic, auth: RFC.auth },
    { salt: Buffer.from(RFC.salt, "base64url"), senderPrivate: Buffer.from(RFC.asPrivate, "base64url") });
  assert.equal(sealed.toString("base64url"), RFC.message);
});

/// What the browser does with a message: the receiving half, written apart from the sender.
function open(sealed, { uaPrivate, uaPublic, auth }) {
  const hmac = (k, d) => createHmac("sha256", k).update(d).digest();
  const hkdf = (salt, ikm, info, n) => hmac(hmac(salt, ikm), Buffer.concat([info, Buffer.from([1])])).subarray(0, n);
  const salt = sealed.subarray(0, 16), idLen = sealed[20], as = sealed.subarray(21, 21 + idLen), body = sealed.subarray(21 + idLen);
  const ecdh = createECDH("prime256v1");
  ecdh.setPrivateKey(Buffer.from(uaPrivate, "base64url"));
  const ua = Buffer.from(uaPublic, "base64url");
  const ikm = hkdf(Buffer.from(auth, "base64url"), ecdh.computeSecret(as), Buffer.concat([Buffer.from("WebPush: info\0"), ua, as]), 32);
  const d = createDecipheriv("aes-128-gcm", hkdf(salt, ikm, Buffer.from("Content-Encoding: aes128gcm\0"), 16), hkdf(salt, ikm, Buffer.from("Content-Encoding: nonce\0"), 12));
  d.setAuthTag(body.subarray(body.length - 16));
  const plain = Buffer.concat([d.update(body.subarray(0, body.length - 16)), d.final()]);
  assert.equal(plain[plain.length - 1], 2);
  return plain.subarray(0, -1).toString();
}

test("a message sealed with fresh random keys opens with the browser's key, and only for that browser", () => {
  const browser = createECDH("prime256v1");
  browser.generateKeys();
  const keys = { uaPrivate: browser.getPrivateKey().toString("base64url"), uaPublic: browser.getPublicKey().toString("base64url"), auth: Buffer.alloc(16, 7).toString("base64url") };
  const note = JSON.stringify({ title: "Price drop", body: "Crème — now $12 ☕" });
  const a = encrypt(note, { p256dh: keys.uaPublic, auth: keys.auth }), b = encrypt(note, { p256dh: keys.uaPublic, auth: keys.auth });
  assert.equal(open(a, keys), note);
  assert.notDeepEqual(a, b, "a new salt and sender key every message");
  assert.throws(() => open(a, { ...keys, auth: Buffer.alloc(16, 8).toString("base64url") }));
  assert.throws(() => encrypt("x".repeat(MAX_PAYLOAD + 1), { p256dh: keys.uaPublic, auth: keys.auth }), /too long/);
  for (const bad of [{ p256dh: "AAAA", auth: keys.auth }, { p256dh: keys.uaPublic, auth: "AAAA" }, {}]) assert.throws(() => encrypt("x", bad), /Bad subscription keys/);
});

test("the sender's token is signed with our key for that push service, for 12 hours", () => {
  const k = generateKeys(), now = Date.UTC(2026, 10, 10);
  const header = vapidHeader("https://fcm.googleapis.com/fcm/send/abc", { ...k, subject: "mailto:hello@marracat.com" }, now);
  const [, token, key] = header.match(/^vapid t=([^,]+), k=(.+)$/);
  assert.equal(key, k.publicKey);
  const [h, p, s] = token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { typ: "JWT", alg: "ES256" });
  assert.deepEqual(JSON.parse(Buffer.from(p, "base64url")), { aud: "https://fcm.googleapis.com", exp: now / 1000 + 12 * 3600, sub: "mailto:hello@marracat.com" });
  const pub = Buffer.from(k.publicKey, "base64url");
  const publicKey = createPublicKey({ format: "jwk", key: { kty: "EC", crv: "P-256", x: pub.subarray(1, 33).toString("base64url"), y: pub.subarray(33).toString("base64url") } });
  assert.ok(verify("sha256", Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s, "base64url")));
});

test("only a browser's own push service is ever posted to", () => {
  for (const ok of ["https://fcm.googleapis.com/fcm/send/x", "https://updates.push.services.mozilla.com/wpush/v2/x", "https://web.push.apple.com/Qx", "https://wns2-by3p.notify.windows.com/w/?token=x"])
    assert.equal(pushEndpoint(ok), ok);
  for (const bad of ["http://fcm.googleapis.com/x", "https://127.0.0.1/x", "https://marracat.com/api/x", "https://fcm.googleapis.com.evil.example/x", "https://evil.example/?fcm.googleapis.com",
    "https://fcm.googleapis.com:8443/x", "https://user:pw@fcm.googleapis.com/x", "file:///etc/passwd", "", null, 5, "https://" + "a".repeat(1200)])
    assert.equal(pushEndpoint(bad), null, String(bad));
});

const browserKeys = () => {
  const b = createECDH("prime256v1");
  b.generateKeys();
  return { p256dh: b.getPublicKey().toString("base64url"), auth: Buffer.alloc(16, 3).toString("base64url") };
};

test("alerts go to every browser the account turned on, and a browser that left is forgotten", async () => {
  const db = new Database(":memory:");
  installWebPushSchema(db);
  const add = (endpoint, user) => db.prepare("INSERT INTO web_push_subs VALUES(?,?,?,?,?)").run(endpoint, user, browserKeys().p256dh, browserKeys().auth, 1);
  add("https://fcm.googleapis.com/fcm/send/live", "u1");
  add("https://fcm.googleapis.com/fcm/send/gone", "u1");
  add("https://web.push.apple.com/other", "u2");
  const posts = [];
  const sender = webPushSender(generateKeysEnv(), { log: () => {}, fetcher: async (url, init) => { posts.push([url, init]); return { status: url.endsWith("gone") ? 410 : 201 }; } });
  assert.equal(await sender.sendToUser(db, "u1", noteFromAPNs({ aps: { alert: { title: "Price drop", body: "Now $9" } }, productID: "a b" })), true);
  assert.deepEqual(posts.map((p) => p[0]), ["https://fcm.googleapis.com/fcm/send/live", "https://fcm.googleapis.com/fcm/send/gone"]);
  assert.equal(posts[0][1].headers["Content-Encoding"], "aes128gcm");
  assert.match(posts[0][1].headers.Authorization, /^vapid t=/);
  assert.deepEqual(db.prepare("SELECT endpoint FROM web_push_subs ORDER BY endpoint").all().map((r) => r.endpoint), ["https://fcm.googleapis.com/fcm/send/live", "https://web.push.apple.com/other"]);
  assert.equal(await sender.sendToUser(db, "nobody", { title: "x" }), false);
  deleteWebPushData(db, "u1");
  assert.equal(db.prepare("SELECT COUNT(*) n FROM web_push_subs").get().n, 1);
  assert.equal(webPushSender({}), null, "no keys, no sender");
});
function generateKeysEnv() {
  const k = generateKeys();
  return { WEB_PUSH_PUBLIC_KEY: k.publicKey, WEB_PUSH_PRIVATE_KEY: k.privateKey };
}

test("an alert written for the phone opens the right page in the browser", () => {
  assert.deepEqual(noteFromAPNs({ aps: { alert: { title: "Price drop", body: "Now $9" } }, productID: "a b" }), { title: "Price drop", body: "Now $9", url: "/p/a%20b", tag: "a b" });
  assert.equal(noteFromAPNs({ aps: { alert: { title: "Sale" } }, brandID: "telfar" }).url, "/b/telfar");
  assert.deepEqual(noteFromAPNs({}), { title: "Marracat", body: "", url: "/", tag: "marracat" });
});

test("/api/push: signed-in only, validated, one row per browser, a welcome on first turn-on", async () => {
  const db = new Database(":memory:");
  const posts = [];
  const sender = webPushSender(generateKeysEnv(), { log: () => {}, fetcher: async (url) => { posts.push(url); return { status: 201 }; } });
  let user = null;
  const app = express();
  webPushRoutes(app, db, { sender, viewer: async () => user, maxPerUser: 2 });
  const off = express();
  webPushRoutes(off, new Database(":memory:"), { sender: null, viewer: async () => ({ id: "u1" }) });
  const server = app.listen(0, "127.0.0.1"), offServer = off.listen(0, "127.0.0.1"); await Promise.all([server, offServer].map((s) => new Promise((r) => s.once("listening", r))));
  const base = `http://127.0.0.1:${server.address().port}/api/push`;
  const call = (path, method, body) => fetch(base + path, { method, headers: { "Content-Type": "application/json" }, body: body && JSON.stringify(body) });
  try {
    assert.equal((await fetch(`http://127.0.0.1:${offServer.address().port}/api/push/key`)).status, 404, "no keys configured: no feature");
    assert.equal((await (await call("/key", "GET")).json()).key, sender.publicKey);
    const sub = (n) => ({ endpoint: "https://fcm.googleapis.com/fcm/send/" + n, keys: browserKeys() });
    assert.equal((await call("/subscribe", "POST", sub(1))).status, 401);
    user = { id: "u1" };
    assert.equal((await call("/subscribe", "POST", { endpoint: "https://evil.example/x", keys: browserKeys() })).status, 400);
    assert.equal((await call("/subscribe", "POST", { endpoint: sub(1).endpoint, keys: { p256dh: "short", auth: "x" } })).status, 400);
    assert.equal((await call("/subscribe", "POST", { endpoint: sub(1).endpoint, keys: { p256dh: "A".repeat(87), auth: "A".repeat(22) } })).status, 400, "not a point on the curve");
    assert.equal(posts.length, 0);
    const one = sub(1);
    assert.equal((await call("/subscribe", "POST", one)).status, 200);
    assert.equal((await call("/subscribe", "POST", one)).status, 200);
    assert.deepEqual(posts, [one.endpoint], "the welcome is sent once");
    assert.equal((await (await call("/", "GET")).json()).browsers, 1);
    // A third browser pushes out the oldest; the cap holds.
    await call("/subscribe", "POST", sub(2));
    await call("/subscribe", "POST", sub(3));
    assert.deepEqual(db.prepare("SELECT endpoint FROM web_push_subs ORDER BY endpoint").all().map((r) => r.endpoint.slice(-1)), ["2", "3"]);
    // Someone else can't turn off this account's browser.
    user = { id: "u2" };
    await call("/subscribe", "DELETE", { endpoint: sub(2).endpoint });
    assert.equal(db.prepare("SELECT COUNT(*) n FROM web_push_subs").get().n, 2);
    user = { id: "u1" };
    await call("/subscribe", "DELETE", { endpoint: sub(2).endpoint });
    assert.equal(db.prepare("SELECT COUNT(*) n FROM web_push_subs").get().n, 1);
  } finally {
    server.close();
    offServer.close();
  }
});
