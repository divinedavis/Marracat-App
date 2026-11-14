import { test } from "node:test";
import assert from "node:assert/strict";
import { readText, storeRedirect, getStoreJSON } from "../server/store-fetch.js";
import { fetchLive } from "../server/restock.js";

const stream = (parts) => new Response(new ReadableStream({
  start(c) { for (const p of parts) c.enqueue(new TextEncoder().encode(p)); c.close(); },
}));

// 2026-11-12: `await res.text()` read a store's whole answer before any size
// check, on a 2 GB server.
test("a body is read only up to its cap", async () => {
  assert.equal(await readText(stream(["ab", "cd"]), 4), "abcd");
  assert.equal(await readText(stream(["ab", "cd", "ef"]), 4), null);
  assert.equal(await readText(stream(["ab", "cd", "ef"]), 5, { truncate: true }), "abcde");
  let pulled = 0;
  const endless = new Response(new ReadableStream({ pull(c) { pulled++; c.enqueue(new Uint8Array(1024)); } }));
  assert.equal(await readText(endless, 4096), null);
  assert.ok(pulled < 20, "reading stopped at the cap");
  const declared = new Response("x", { headers: { "content-length": "9999999" } });
  assert.equal(await readText(declared, 100), null, "a declared length over the cap isn't read");
  assert.equal(await readText({ text: async () => "plain" }, 10), "plain", "a test double with only text()");
  assert.equal(await readText({ text: async () => "x".repeat(11) }, 10), null);
});

test("a store may redirect once, to itself or its myshopify.com name, over https", () => {
  const from = "https://koba.com/products/oil.js";
  assert.equal(storeRedirect("https://www.koba.com/products/oil.js", from, "koba.com"), "https://www.koba.com/products/oil.js");
  assert.equal(storeRedirect("/products/oil.js?x=1", from, "koba.com"), "https://koba.com/products/oil.js?x=1");
  assert.equal(storeRedirect("https://koba.myshopify.com/products/oil.js", from, "koba.com"), "https://koba.myshopify.com/products/oil.js");
  for (const bad of ["http://koba.com/products/oil.js", "https://127.0.0.1/products/oil.js", "http://169.254.169.254/latest/meta-data",
    "https://evil.example/products/oil.js", "https://koba.com:8443/products/oil.js", "https://[::1]/products/oil.js",
    "https://user:pw@koba.com/products/oil.js", "", null])
    assert.equal(storeRedirect(bad, from, "koba.com"), null, String(bad));
  assert.equal(storeRedirect("https://koba.com/admin", from, "koba.com", { path: /^\/products\/[^/]+\.js$/ }), null);
});

test("the restock check no longer follows a store's redirect off the store", async () => {
  const seen = [];
  const hop = (location) => async (url, opts) => {
    seen.push([url, opts.redirect]);
    if (seen.length === 1) return new Response(null, { status: 302, headers: { location } });
    return new Response(JSON.stringify({ available: true, variants: [] }));
  };
  assert.equal(await fetchLive("https://koba.com/products/oil.js", hop("http://127.0.0.1:3107/api/owner/metrics")), null);
  assert.deepEqual(seen, [["https://koba.com/products/oil.js", "manual"]], "the internal address was never asked");
  seen.length = 0;
  assert.deepEqual(await fetchLive("https://koba.com/products/oil.js", hop("https://www.koba.com/products/oil.js")), { available: true, variants: [] });
  assert.equal(seen[1][0], "https://www.koba.com/products/oil.js");
  seen.length = 0;
  const loop = async (url) => { seen.push(url); return new Response(null, { status: 301, headers: { location: "https://www.koba.com/products/oil.js" } }); };
  assert.equal(await getStoreJSON("https://koba.com/products/oil.js", loop, { max: 1000, timeoutMs: 1000 }), null);
  assert.equal(seen.length, 2, "one redirect, not a chain");
});
