import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { readFileSync } from "node:fs";
import { createECDH } from "node:crypto";
import { socialRoutes, deleteSocialData } from "../server/social.js";
import { seal, open, toB64, generateDeviceKey, exportPublic, sealForFriends } from "../src/e2ee.js";
import { refusal } from "../server/content-filter.js";

const OWNER = "owner@example.test";

async function fixture(t) {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT,email TEXT)");
  db.exec("CREATE TABLE mobile_sessions(hash TEXT PRIMARY KEY,user_id TEXT,expires INTEGER)");
  const people = { alice: "Alice Adams", bob: "Bob Brown", cara: "Cara Cole", owner: "Store Owner" };
  for (const [id, name] of Object.entries(people))
    db.prepare("INSERT INTO users(id,name,email) VALUES(?,?,?)").run(id, name, id === "owner" ? OWNER : `${id}@example.test`);
  const app = express();
  // Tests say who is asking with a header; production resolves the bearer
  // token or the web session.
  socialRoutes(app, db, {
    env: { OWNER_EMAILS: OWNER, NODE_ENV: "production" },
    viewer: (req) => {
      const id = req.get("X-Test-User");
      const user = id && db.prepare("SELECT id,name,email FROM users WHERE id=?").get(id);
      return user ? { ...user, via: req.get("X-Test-Via") || "app" } : null;
    },
  });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => { server.close(); db.close(); });
  const base = `http://127.0.0.1:${server.address().port}/api/social/`;
  const call = async (who, path, body, method = body ? "POST" : "GET", headers = {}) => {
    const r = await fetch(base + path, {
      method,
      headers: { "Content-Type": "application/json", ...(who ? { "X-Test-User": who } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined,
    });
    return { status: r.status, data: r.status === 204 ? null : await r.json() };
  };
  const agree = (who) => call(who, "terms", { agree: true });
  const handle = async (who) => (await call(who, "me")).data.profile.handle;
  return { db, call, agree, handle };
}

test("profiles are made on first use, show a short name, and never expose emails or ids", async (t) => {
  const { call } = await fixture(t);
  const me = await call("alice", "me");
  assert.equal(me.status, 200);
  assert.equal(me.data.profile.name, "Alice A.");
  assert.match(me.data.profile.handle, /^alicea\d{4}$/);
  assert.ok(!JSON.stringify(me.data).includes("example.test"));
  assert.ok(!JSON.stringify(me.data).includes('"alice"'));
  assert.equal((await call(null, "me")).status, 401);
});

test("handles are unique, well formed and can't impersonate the store", async (t) => {
  const { call } = await fixture(t);
  assert.equal((await call("alice", "me", { handle: "alice" }, "PATCH")).status, 200);
  assert.equal((await call("bob", "me", { handle: "alice" }, "PATCH")).status, 409);
  assert.equal((await call("bob", "me", { handle: "marracat" }, "PATCH")).status, 422);
  assert.equal((await call("bob", "me", { handle: "no spaces" }, "PATCH")).status, 400);
  assert.equal((await call("bob", "me", { name: "a nigga" }, "PATCH")).status, 422);
  const ok = await call("bob", "me", { handle: "@Bobby_B", name: "  Bobby   B " }, "PATCH");
  assert.deepEqual(ok.data.profile, { handle: "bobby_b", name: "Bobby B" });
});

test("comments need agreed terms, pass the filter, and nest only one level", async (t) => {
  const { call, agree } = await fixture(t);
  const first = await call("alice", "products/p1/comments", { body: "Love this" });
  assert.equal(first.status, 428);
  assert.equal(first.data.code, "terms_required");
  await agree("alice");
  await agree("bob");
  assert.equal((await call("alice", "products/p1/comments", { body: "check brand.com" })).status, 422);
  assert.equal((await call("alice", "products/p1/comments", { body: "k y s" })).status, 422);
  assert.equal((await call("alice", "products/p1/comments", { body: " " })).status, 400);
  const root = await call("alice", "products/p1/comments", { body: "Love this oil" });
  assert.equal(root.status, 201);
  const reply = await call("bob", "products/p1/comments", { body: "Same", parent_id: root.data.id });
  // A reply to a reply joins the same thread rather than nesting deeper.
  const deeper = await call("alice", "products/p1/comments", { body: "Right?", parent_id: reply.data.id });
  assert.equal(deeper.data.parent_id, root.data.id);
  const list = (await call(null, "products/p1/comments")).data.comments;
  assert.equal(list.length, 1);
  assert.deepEqual(list[0].replies.map((r) => r.body), ["Same", "Right?"]);
  assert.ok(list[0].replies.every((r) => !("replies" in r)));
  assert.equal(list[0].author.name, "Alice A.");
  // A reply can't be attached to another product's comment.
  assert.equal((await call("bob", "products/p2/comments", { body: "x", parent_id: root.data.id })).status, 404);
});

test("deleting keeps other people's replies, and only the author or the owner can delete", async (t) => {
  const { call, agree } = await fixture(t);
  await agree("alice"); await agree("bob");
  const root = await call("alice", "products/p1/comments", { body: "Root" });
  await call("bob", "products/p1/comments", { body: "Reply", parent_id: root.data.id });
  assert.equal((await call("bob", `comments/${root.data.id}`, null, "DELETE")).status, 403);
  await call("alice", `comments/${root.data.id}`, null, "DELETE");
  const [thread] = (await call(null, "products/p1/comments")).data.comments;
  assert.equal(thread.deleted, true);
  assert.equal(thread.body, "");
  assert.equal(thread.author, null);
  assert.equal(thread.replies[0].body, "Reply");
  const lone = await call("bob", "products/p1/comments", { body: "Lonely" });
  assert.equal((await call("owner", `comments/${lone.data.id}`, null, "DELETE")).status, 200);
  assert.equal((await call(null, "products/p1/comments")).data.comments.length, 1);
});

test("likes: one per person, counted for everyone, marked for the liker, gone with a deleted account", async (t) => {
  const { call, db } = await fixture(t);
  for (const who of ["alice", "bob", "cara"]) await call(who, "terms", { agree: true });
  const root = await call("alice", "products/p1/comments", { body: "Love this" });
  assert.equal((await call(null, `comments/${root.data.id}/like`, {})).status, 401, "liking needs an account");
  assert.deepEqual((await call("bob", `comments/${root.data.id}/like`, {})).data, { likes: 1, liked: true });
  assert.deepEqual((await call("bob", `comments/${root.data.id}/like`, {})).data, { likes: 1, liked: true }, "twice is once");
  await call("cara", `comments/${root.data.id}/like`, {});
  const [seenByBob] = (await call("bob", "products/p1/comments")).data.comments;
  assert.equal(seenByBob.likes, 2);
  assert.equal(seenByBob.liked, true);
  const [seenByAnyone] = (await call(null, "products/p1/comments")).data.comments;
  assert.equal(seenByAnyone.liked, false);
  assert.deepEqual((await call("bob", `comments/${root.data.id}/like`, null, "DELETE")).data, { likes: 1, liked: false });
  assert.equal((await call("bob", "comments/nope/like", {})).status, 404);
  // Blocked either way: no liking each other's comments.
  await call("alice", "users/" + (await call("cara", "me")).data.profile.handle + "/block", {});
  assert.equal((await call("cara", `comments/${root.data.id}/like`, {})).status, 404);
  deleteSocialData(db, "cara");
  assert.equal((await call(null, "products/p1/comments")).data.comments[0].likes, 0, "a deleted account's likes go");
});

test("a report hides a comment for everyone but its author and the owner, until reviewed", async (t) => {
  const { call, agree } = await fixture(t);
  await agree("alice"); await agree("bob");
  const c = await call("alice", "products/p1/comments", { body: "Borderline" });
  assert.equal((await call("alice", `comments/${c.data.id}/report`, {})).status, 400);
  await call("bob", `comments/${c.data.id}/report`, { reason: "rude" });
  assert.equal((await call("cara", "products/p1/comments")).data.comments.length, 0);
  assert.equal((await call(null, "products/p1/comments")).data.comments.length, 0);
  assert.equal((await call("alice", "products/p1/comments")).data.comments[0].under_review, true);
  assert.equal((await call("owner", "products/p1/comments")).data.comments.length, 1);
  // Only the owner sees the queue.
  assert.equal((await call("bob", "moderation")).status, 404);
  const [r] = (await call("owner", "moderation")).data.reports;
  assert.equal(r.subject.body, "Borderline");
  await call("owner", `moderation/${r.id}`, { action: "restore" });
  assert.equal((await call("cara", "products/p1/comments")).data.comments.length, 1);
  assert.equal((await call("owner", "moderation")).data.reports.length, 0);
});

test("suspending an author stops them posting", async (t) => {
  const { call, agree } = await fixture(t);
  await agree("alice"); await agree("bob");
  const c = await call("alice", "products/p1/comments", { body: "Spam spam" });
  await call("bob", `comments/${c.data.id}/report`, {});
  const [r] = (await call("owner", "moderation")).data.reports;
  await call("owner", `moderation/${r.id}`, { action: "suspend" });
  assert.equal((await call("cara", "products/p1/comments")).data.comments.length, 0);
  assert.equal((await call("alice", "products/p1/comments", { body: "again" })).status, 403);
});

test("blocking hides both people from each other and ends the friendship", async (t) => {
  const { call, agree, handle } = await fixture(t);
  await agree("alice"); await agree("bob");
  const a = await handle("alice"), b = await handle("bob");
  await call("alice", `users/${b}/friend`, {});
  assert.equal((await call("bob", `users/${a}/friend`, {})).data.relationship, "friends");
  await call("alice", "products/p1/comments", { body: "From Alice" });
  const fromBob = await call("bob", "products/p1/comments", { body: "From Bob" });
  await call("alice", `comments/${fromBob.data.id}/block`, {});
  const seenByAlice = (await call("alice", "products/p1/comments")).data.comments.map((c) => c.body);
  const seenByBob = (await call("bob", "products/p1/comments")).data.comments.map((c) => c.body);
  assert.deepEqual(seenByAlice, ["From Alice"]);
  assert.deepEqual(seenByBob, ["From Bob"]);
  assert.equal((await call("bob", "friends")).data.friends.length, 0);
  assert.equal((await call("bob", `users/${a}`)).status, 404);
  assert.equal((await call("bob", `users/${a}/friend`, {})).status, 404);
  assert.equal((await call("bob", "search?q=ali")).data.people.length, 0);
  // Alice can still find Bob to unblock him.
  assert.equal((await call("alice", `users/${b}`)).data.relationship, "blocked");
  await call("alice", `users/${b}/block`, null, "DELETE");
  assert.equal((await call("alice", `users/${b}`)).data.relationship, "none");
});

test("friend requests: send, accept by asking back, decline, cancel", async (t) => {
  const { call, handle } = await fixture(t);
  const a = await handle("alice"), b = await handle("bob"), c = await handle("cara");
  assert.equal((await call("alice", `users/${b}/friend`, {})).data.relationship, "requested");
  assert.equal((await call("bob", `users/${a}`)).data.relationship, "incoming");
  assert.equal((await call("bob", "me")).data.counts.incoming, 1);
  assert.equal((await call("bob", `users/${a}/friend`, {})).data.relationship, "friends");
  await call("alice", `users/${c}/friend`, {});
  await call("cara", `users/${a}/friend`, null, "DELETE"); // decline
  assert.deepEqual((await call("alice", "friends")).data, {
    friends: [{ handle: b, name: "Bob B." }], incoming: [], outgoing: [],
  });
  assert.equal((await call("alice", `users/${a}/friend`, {})).status, 400);
});

test("a cookie-signed-in write from another site is refused", async (t) => {
  const { call, agree } = await fixture(t);
  await agree("alice");
  const foreign = await call("alice", "products/p1/comments", { body: "hi" }, "POST", { "X-Test-Via": "web", Origin: "https://evil.test" });
  assert.equal(foreign.status, 403);
  const own = await call("alice", "products/p1/comments", { body: "hi" }, "POST", { "X-Test-Via": "web", Origin: "https://marracat.com" });
  assert.equal(own.status, 201);
  // The app authenticates with a bearer token and sends no Origin.
  assert.equal((await call("alice", "products/p1/comments", { body: "hi again" })).status, 201);
});

test("the encryption matches the shared test vector byte for byte", async () => {
  const v = JSON.parse(readFileSync(new URL("./fixtures/share-vector.json", import.meta.url)));
  const b64u = (b) => Buffer.from(b).toString("base64url");
  const pub = (hex) => { const e = createECDH("prime256v1"); e.setPrivateKey(Buffer.from(hex, "hex")); return e.getPublicKey(); };
  const jwk = (hex) => { const p = pub(hex); return { kty: "EC", crv: "P-256", d: b64u(Buffer.from(hex, "hex")), x: b64u(p.subarray(1, 33)), y: b64u(p.subarray(33)) }; };
  const C = { name: "ECDH", namedCurve: "P-256" };
  const ephemeral = {
    privateKey: await crypto.subtle.importKey("jwk", jwk(v.ephemeral_private), C, true, ["deriveBits"]),
    publicKey: await crypto.subtle.importKey("raw", pub(v.ephemeral_private), C, true, []),
  };
  const sealed = await seal(v.recipient_public, v.message, { ephemeral, nonce: Buffer.from(v.envelope.nonce, "base64") });
  assert.deepEqual(sealed, v.envelope);
  const recipient = await crypto.subtle.importKey("jwk", jwk(v.recipient_private), C, false, ["deriveBits"]);
  assert.deepEqual(await open(recipient, v.recipient_public, v.envelope), v.message);
  // One flipped bit and it won't open.
  const bad = Buffer.from(v.envelope.ciphertext, "base64"); bad[3] ^= 1;
  await assert.rejects(() => open(recipient, v.recipient_public, { ...v.envelope, ciphertext: bad.toString("base64") }));
});

test("shares are sealed per device, only friends can receive them, and the server never sees the product", async (t) => {
  const { call, agree, handle, db } = await fixture(t);
  await agree("alice"); await agree("bob");
  const a = await handle("alice"), b = await handle("bob"), c = await handle("cara");
  await call("alice", `users/${b}/friend`, {}); await call("bob", `users/${a}/friend`, {});
  // Bob has a phone and a laptop.
  const phone = await generateDeviceKey(), laptop = await generateDeviceKey();
  const phoneID = (await call("bob", "devices", { public_key: await exportPublic(phone.publicKey) })).data.device_id;
  const laptopID = (await call("bob", "devices", { public_key: await exportPublic(laptop.publicKey) })).data.device_id;
  assert.equal((await call("bob", "devices", { public_key: "bm90IGEga2V5" })).status, 400);
  // Strangers' keys aren't handed out.
  const cara = await generateDeviceKey();
  await call("cara", "devices", { public_key: await exportPublic(cara.publicKey) });
  const keys = (await call("alice", `keys?handles=${b},${c}`)).data.keys;
  assert.deepEqual(Object.keys(keys), [b]);
  assert.equal(keys[b].length, 2);

  const message = { product_id: "koba-skincare-123", note: "For your wash day" };
  const { messages, unreachable } = await sealForFriends(keys, [b], message);
  assert.deepEqual(unreachable, []);
  assert.equal((await call("alice", "shares", { messages })).status, 201);
  // Nothing readable is stored.
  const stored = JSON.stringify(db.prepare("SELECT * FROM shares").all()) + JSON.stringify(db.prepare("SELECT * FROM share_envelopes").all());
  assert.ok(!stored.includes("koba") && !stored.includes("wash day"));
  // Each of Bob's devices opens its own envelope.
  for (const [id, key] of [[phoneID, phone], [laptopID, laptop]]) {
    const [share] = (await call("bob", `shares?device=${id}`)).data.shares;
    assert.equal(share.from.handle, a);
    assert.deepEqual(await open(key.privateKey, await exportPublic(key.publicKey), share.envelope), message);
  }
  // A device the server has forgotten is told so, to make a new key.
  assert.equal((await call("bob", "shares?device=forgotten")).data.device_known, false);
  assert.equal((await call("bob", `shares?device=${phoneID}`)).data.device_known, true);
  // A device that wasn't registered when it was sent gets no envelope.
  const later = await generateDeviceKey();
  const laterID = (await call("bob", "devices", { public_key: await exportPublic(later.publicKey) })).data.device_id;
  assert.equal((await call("bob", `shares?device=${laterID}`)).data.shares[0].envelope, null);
  // Not a friend: refused. An envelope aimed at someone else's device: refused.
  const toCara = [{ to: c, envelopes: [{ device_id: phoneID, ...(await seal(await exportPublic(cara.publicKey), message)) }] }];
  assert.equal((await call("alice", "shares", { messages: toCara })).status, 400);
  const misdirected = [{ to: b, envelopes: [{ device_id: "someone-elses", ...(await seal(await exportPublic(phone.publicKey), message)) }] }];
  assert.equal((await call("alice", "shares", { messages: misdirected })).status, 400);
});

test("reporting a share sends only what the reporter's device decrypted", async (t) => {
  const { call, agree, handle } = await fixture(t);
  await agree("alice"); await agree("bob");
  const a = await handle("alice"), b = await handle("bob");
  await call("alice", `users/${b}/friend`, {}); await call("bob", `users/${a}/friend`, {});
  const key = await generateDeviceKey();
  const id = (await call("bob", "devices", { public_key: await exportPublic(key.publicKey) })).data.device_id;
  const { messages } = await sealForFriends((await call("alice", `keys?handles=${b}`)).data.keys, [b], { product_id: "p9", note: "nasty" });
  await call("alice", "shares", { messages });
  const [share] = (await call("bob", `shares?device=${id}`)).data.shares;
  const opened = await open(key.privateKey, await exportPublic(key.publicKey), share.envelope);
  await call("bob", `shares/${share.id}/report`, { message: opened });
  const [r] = (await call("owner", "moderation")).data.reports;
  assert.equal(r.kind, "share");
  assert.equal(r.subject.note, "nasty");
  await call("owner", `moderation/${r.id}`, { action: "remove" });
  assert.equal((await call("bob", `shares?device=${id}`)).data.shares.length, 0);
});

test("deleting an account removes everything social and keeps others' threads", async (t) => {
  const { call, agree, handle, db } = await fixture(t);
  await agree("alice"); await agree("bob");
  const a = await handle("alice"), b = await handle("bob");
  await call("alice", `users/${b}/friend`, {}); await call("bob", `users/${a}/friend`, {});
  const root = await call("alice", "products/p1/comments", { body: "Mine" });
  await call("bob", "products/p1/comments", { body: "Bob's reply", parent_id: root.data.id });
  const key = await generateDeviceKey();
  await call("alice", "devices", { public_key: await exportPublic(key.publicKey) });
  deleteSocialData(db, "alice");
  for (const [table, col] of [["profiles", "user_id"], ["devices", "user_id"], ["ugc_terms", "user_id"]])
    assert.equal(db.prepare(`SELECT COUNT(*) n FROM ${table} WHERE ${col}='alice'`).get().n, 0, table);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM friends").get().n, 0);
  assert.equal(db.prepare("SELECT COUNT(*) n FROM comments WHERE user_id='alice'").get().n, 0);
  const [thread] = (await call(null, "products/p1/comments")).data.comments;
  assert.equal(thread.deleted, true);
  assert.equal(thread.replies[0].body, "Bob's reply");
});

test("the content filter", () => {
  assert.equal(refusal("This oil is the shit"), null);
  assert.equal(refusal("rapeseed and grape"), null);
  assert.ok(refusal("f4gg0t"));
  assert.ok(refusal("go to www.spam.shop"));
});
