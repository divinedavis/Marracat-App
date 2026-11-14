import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { installSocialSchema } from "../server/social.js";
import { commentFeedRoutes, recentComments, FEED_SIZE } from "../server/comment-feed.js";

const products = {
  "koba-1": { id: "koba-1", title: "Keep It Together Headband", brand: "KOBA", image: "https://cdn.example/h.jpg" },
  "koba-2": { id: "koba-2", title: "Lip Oil", brand: "KOBA", image: null },
  "fog-1": { id: "fog-1", title: "Classic Sweatpant", brand: "Fear of God", image: null },
  "x-3": { id: "x-3", title: "Tote", brand: "X", image: null },
};
const card = (id) => products[id] || null;

function seed() {
  const db = new Database(":memory:");
  installSocialSchema(db);
  for (const [id, handle] of [["alice", "alice1"], ["bob", "bob22"], ["cara", "cara33"], ["dan", "dan44"]])
    db.prepare("INSERT INTO profiles(user_id,handle,display_name,created_at) VALUES(?,?,?,?)").run(id, handle, id[0].toUpperCase() + id.slice(1), 1);
  let t = 1000;
  const comment = (id, user, product, body, extra = {}) =>
    db.prepare(`INSERT INTO comments(id,product_id,user_id,parent_id,body,created_at,hidden_at,deleted_at) VALUES(?,?,?,?,?,?,?,?)`)
      .run(id, product, user, extra.parent ?? null, body, (t += 10), extra.hidden ?? null, extra.deleted ?? null);
  comment("c1", "alice", "koba-1", "Love this headband, so soft");
  comment("c2", "bob", "koba-1", "Mine came in two days"); // newer, same product: only this one shows
  comment("c3", "cara", "fog-1", "Hidden after a report", { hidden: 5 });
  comment("c4", "cara", "x-3", "Removed by its author", { deleted: 5 });
  comment("c5", "alice", "koba-2", "A reply, not a top comment", { parent: "c1" });
  comment("c6", "dan", "fog-1", "Suspended author's comment");
  db.prepare("INSERT INTO user_flags(user_id,suspended_at) VALUES('dan',1)").run();
  comment("c7", "alice", "gone-9", "Product left the catalog");
  comment("c8", "alice", "x-3", "Great tote <b>for</b> the gym");
  return db;
}

test("only visible top-level comments with a live product, one a product, newest first", () => {
  const ids = recentComments(seed(), card).map((c) => c.id);
  assert.deepEqual(ids, ["c8", "c2"]);
});

test("the feed hides blocked people from a signed-in viewer and never returns user ids", async (t) => {
  const db = seed();
  db.prepare("INSERT INTO blocks(user_id,blocked_id,created_at) VALUES('carl','bob',1)").run();
  const app = express();
  let clock = 0;
  commentFeedRoutes(app, db, { card, now: () => clock, viewer: async (req) => (req.get("X-Test-User") ? { id: req.get("X-Test-User") } : null) });
  const s = app.listen(0, "127.0.0.1");
  await new Promise((r) => s.once("listening", r));
  t.after(() => { s.close(); db.close(); });
  const get = async (who) => {
    const r = await fetch(`http://127.0.0.1:${s.address().port}/api/comments/recent`, { headers: who ? { "X-Test-User": who } : {} });
    assert.equal(r.headers.get("cache-control"), "no-store");
    return (await r.json()).comments;
  };
  const anon = await get();
  assert.deepEqual(anon.map((c) => c.id), ["c8", "c2"]);
  assert.deepEqual(Object.keys(anon[0]).sort(), ["author", "body", "created_at", "id", "product"]);
  assert.deepEqual(anon[0].author, { handle: "alice1", name: "Alice" });
  assert.equal(anon[0].body, "Great tote <b>for</b> the gym", "text comes back as text; React escapes it");
  assert.deepEqual((await get("carl")).map((c) => c.id), ["c8"], "carl blocked bob");
  // A comment hidden after the list was built leaves within the minute cache.
  db.prepare("UPDATE comments SET hidden_at=9 WHERE id='c8'").run();
  assert.deepEqual((await get()).map((c) => c.id), ["c8", "c2"], "still cached");
  clock = 61_000;
  assert.deepEqual((await get()).map((c) => c.id), ["c2"]);
});

test("the feed is capped and long comments are shortened", () => {
  const db = new Database(":memory:");
  installSocialSchema(db);
  db.prepare("INSERT INTO profiles(user_id,handle,display_name,created_at) VALUES('a','aaa1','A',1)").run();
  const many = {};
  for (let i = 0; i < 20; i++) {
    many[`p${i}`] = { id: `p${i}`, title: `P${i}`, brand: "B", image: null };
    db.prepare("INSERT INTO comments(id,product_id,user_id,body,created_at) VALUES(?,?,?,?,?)").run(`c${i}`, `p${i}`, "a", "word ".repeat(100), i);
  }
  const out = recentComments(db, (id) => many[id] || null);
  assert.ok(out.length >= FEED_SIZE);
  assert.ok(out.every((c) => c.body.length <= 240 && c.body.endsWith("…")));
});
