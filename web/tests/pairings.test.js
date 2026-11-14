import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { pairingsRoutes } from "../server/pairings.js";

const products = {
  dress: { id: "dress", category: "clothing" }, earrings: { id: "earrings", category: "jewelry" },
  tee: { id: "tee", category: "clothing" }, candle: { id: "candle", category: "home" },
};
async function fixture(t) {
  const db = new Database(":memory:");
  const app = express();
  app.set("trust proxy", "loopback");   // X-Forwarded-For stands in for distinct shoppers
  pairingsRoutes(app, db, { lookup: (id) => products[id] });
  const server = app.listen(0, "127.0.0.1");
  await new Promise((r) => server.once("listening", r));
  t.after(() => { server.close(); db.close(); });
  const base = `http://127.0.0.1:${server.address().port}/api/pairs`;
  const post = async (ids, key, ip = `10.0.0.${key.charCodeAt(0)}`) => (await fetch(base, { method: "POST", headers: { "Content-Type": "application/json", "X-Marracat-Device": key, "X-Forwarded-For": ip }, body: JSON.stringify({ products: ids }) })).status;
  const pairs = async (id) => (await (await fetch(`${base}?product=${id}`)).json()).pairs;
  return { db, post, pairs };
}

test("a pair shows once three installs have made it, across departments only", async (t) => {
  const { db, post, pairs } = await fixture(t);
  for (const k of ["a", "a", "b"]) assert.equal(await post(["dress", "earrings", "tee", "nope"], k.repeat(64)), 204);
  assert.deepEqual(await pairs("dress"), [], "two installs are not enough, however often one repeats");
  await post(["earrings", "dress"], "c".repeat(64));
  assert.deepEqual(await pairs("dress"), ["earrings"]);
  assert.deepEqual(await pairs("earrings"), ["dress"]);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM pair_installs WHERE a='dress' AND b='tee'").get().n, 0, "same department");
});

// Audit 2026-10-07 (L1): install keys are made up by the client, so pairs are
// counted per IP.
test("one IP posing as many installs can't plant a pair", async (t) => {
  const { post, pairs } = await fixture(t);
  for (const k of ["c", "d", "e", "f"]) assert.equal(await post(["dress", "candle"], k.repeat(64), "203.0.113.9"), 204);
  assert.deepEqual(await pairs("candle"), [], "four keys, one IP: one install");
});

test("bad requests are refused", async (t) => {
  const { post } = await fixture(t);
  assert.equal(await post(["dress"], "a".repeat(64)), 400);
  assert.equal(await post(Array(21).fill("dress"), "a".repeat(64)), 400);
  assert.equal(await post(["dress", "earrings"], "short"), 401);
});
