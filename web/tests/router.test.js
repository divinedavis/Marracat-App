import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { toPath, fromPath } from "../src/router.js";
import { readRecent, rememberSearch, rememberView, forgetRecent } from "../src/recent.js";

// 2026-11-12: "#//evil.example" became the path "//evil.example", which names
// another site; history.replaceState throws on it and the page never loaded.
test("a route is always one path on this site", () => {
  assert.equal(toPath("//evil.example"), "/evil.example");
  assert.equal(toPath("#//evil.example/x?y=1"), "/evil.example/x?y=1");
  assert.equal(toPath("/\\evil.example"), "/evil.example");
  assert.equal(toPath("\\\\evil.example"), "/evil.example");
  assert.equal(toPath("/product?id=koba-1"), "/p/koba-1");
  assert.equal(toPath("#/shop?brand=telfar"), "/b/telfar");
  assert.equal(toPath("account"), "/account");
  assert.equal(toPath(""), "/");
  assert.equal(fromPath("/p/koba-1"), "/product?id=koba-1");
});

// 2026-11-12: a notification's link passed as long as it began with one "/",
// and browsers read "/\host" as "//host".
test("a notification opens a page of ours or the home page", () => {
  const source = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");
  const ownPath = new Function("self", source.match(/function ownPath\(u\) \{[\s\S]*?\n\}/)[0] + "\nreturn ownPath;")({ location: { origin: "https://marracat.com" } });
  assert.equal(ownPath("/p/koba-1"), "/p/koba-1");
  assert.equal(ownPath("/orders?x=1"), "/orders?x=1");
  for (const bad of ["//evil.example", "/\\evil.example", "\\\\evil.example", "https://evil.example/", "javascript:alert(1)", "", null, 7])
    assert.equal(ownPath(bad), "/", String(bad));
});

test("signing out forgets this browser's searches and views", () => {
  const data = new Map();
  const storage = { getItem: (k) => data.get(k) ?? null, setItem: (k, v) => data.set(k, v), removeItem: (k) => data.delete(k) };
  rememberSearch("bag charms", storage);
  rememberView("koba-1", storage);
  assert.deepEqual(readRecent(storage), { searches: ["bag charms"], viewed: ["koba-1"] });
  forgetRecent(storage);
  assert.deepEqual(readRecent(storage), { searches: [], viewed: [] });
  assert.equal(data.size, 0);
});
