import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { catalogRoutes, querySource } from "../server/catalog.js";
import { CHUNK, FORMAT, fromLines, lineSplitter, linesText, readHead, toLines } from "../src/catalog-format.js";
import { adoptWordIndex, adoptedWordIndex, buildWordIndex, filterProducts, pageCandidateMarks, searchScorer, searchWithGuesses, setSearchCategories, wordIndexWriter } from "../src/catalog.js";
import { catalogAssembler } from "../src/catalog-loader.js";
import { createSearchIndex, suggest } from "../src/search-suggestions.js";

// The catalog as lines, read off the main thread and kept on the device
// (owner, 2026-11-10). The page must end up with exactly the catalog the
// one-document download gives it.
const small = {
  generated_at: "2026-11-10T00:00:00Z",
  brands: [{ id: "a", name: "A" }],
  categories: [{ id: "c", name: "C" }],
  subcategories: [],
  products: Array.from({ length: 7 }, (_, i) => ({ id: "p" + i, brand: "a", title: `Thing ${i} é "q" \n ☕`, category: "c" })),
};

test("a catalog survives being written as lines and read back", () => {
  const lines = toLines(small, 3);
  assert.equal(lines.length, 1 + 3);
  assert.deepEqual(readHead(lines[0]).count, 7);
  assert.ok(lines.every((l) => !l.includes("\n")), "a line never holds a newline");
  assert.deepEqual(fromLines(lines), small);
  assert.equal(fromLines(lines.slice(0, 3)), null, "a short read is not a catalog");
  assert.equal(readHead(JSON.stringify(small)), null, "one whole document is not a head");
  assert.equal(readHead("not json"), null);
});

test("lines come out whole however the bytes were cut, accents and all", () => {
  const text = linesText(toLines(small, 2));
  const bytes = new TextEncoder().encode(text);
  for (const size of [1, 2, 3, 7, 64, 100000]) {
    const decoder = new TextDecoder(), split = lineSplitter(), got = [];
    for (let i = 0; i < bytes.length; i += size) got.push(...split.push(decoder.decode(bytes.subarray(i, i + size), { stream: true })));
    got.push(...split.push(decoder.decode()));
    assert.equal(split.rest(), "", `cut at ${size}`);
    assert.deepEqual(fromLines(got), small, `cut at ${size}`);
  }
  // No newline at the end: the last line is what is left.
  const split = lineSplitter();
  assert.deepEqual(split.push("a\nb"), ["a"]);
  assert.equal(split.rest(), "b");
});

test("/api/catalog?lines=1 is the same catalog as /api/catalog, and answers 304 to what it sent", async () => {
  const app = express();
  catalogRoutes(app);
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}/api/catalog?v=5`;
  try {
    const whole = await (await fetch(base)).json();
    const r = await fetch(base + "&lines=1");
    const etag = r.headers.get("etag");
    const lines = (await r.text()).split("\n").filter(Boolean);
    const head = readHead(lines[0]);
    assert.equal(head.format, FORMAT);
    assert.equal(head.count, whole.products.length);
    assert.equal(lines.length, 1 + Math.ceil(whole.products.length / CHUNK));
    assert.deepEqual(fromLines(lines), whole);
    assert.notEqual(etag, (await fetch(base)).headers.get("etag"), "the two forms never share a validator");
    for (const sent of [etag, "W/" + etag]) assert.equal((await fetch(base + "&lines=1", { headers: { "If-None-Match": sent } })).status, 304);
    assert.equal((await fetch(base + "&lines=1", { headers: { "If-None-Match": '"old"' } })).status, 200);
    // Once compressed, the plain text is dropped; a client that takes no
    // compression still gets the catalog.
    const plain = await fetch(base + "&lines=1", { headers: { "Accept-Encoding": "identity" } });
    assert.equal(readHead((await plain.text()).split("\n")[0]).count, whole.products.length);
  } finally {
    server.close();
  }
});

const { products, brands } = querySource();

test("the page puts the worker's lines back together, and starts over on a second head", () => {
  const got = [], errors = [];
  const take = catalogAssembler({ onCatalog: (c, from) => got.push([c, from]), onError: () => errors.push(1) });
  const lines = toLines(small, 3), { format, count, ...head } = JSON.parse(lines[0]);
  take({ type: "products", json: lines[1] }); // before any head: ignored
  take({ type: "head", head, count, from: "device" });
  take({ type: "products", json: lines[1] });
  // The device copy turned out damaged; the network's starts again.
  take({ type: "head", head, count, from: "network" });
  for (const json of lines.slice(1)) take({ type: "products", json });
  assert.equal(got.length, 0, "nothing is handed over before it is complete");
  take({ type: "done", from: "network", count });
  assert.deepEqual(got, [[small, "network"]]);
  // A count that doesn't add up is an error, not a short catalog.
  take({ type: "head", head, count: 99, from: "network" });
  take({ type: "products", json: lines[1] });
  take({ type: "done", from: "network", count: 99 });
  assert.equal(got.length, 1);
  assert.equal(errors.length, 1);
  take({ type: "error" });
  assert.equal(errors.length, 2);
  take(null);
});

test("an index fed a product at a time is the index built over the whole list", () => {
  const whole = buildWordIndex(products, brands);
  const writer = wordIndexWriter(brands);
  for (const p of products) writer.add(p);
  const packed = writer.pack();
  assert.equal(writer.count, products.length);
  assert.deepEqual(packed.words, whole.words);
  assert.deepEqual(packed.starts, whole.starts);
  assert.deepEqual(packed.postings, whole.postings);
});

test("typing suggestions are the same with the index, which spares each keystroke most of the list", () => {
  const typing = createSearchIndex(products, brands, [], []);
  const typed = ["she", "shea b", "red dress", "candl", "lip", "gold hoop", "zzq", "telf"];
  const shown = () => JSON.stringify(typed.map((q) => {
    const s = suggest(typing, q);
    return [s.count, s.categories, s.items.map((i) => [i.type, i.label ?? i.title ?? i.product?.id ?? i.id])];
  }));
  adoptWordIndex(products, brands, null);
  const before = shown();
  const writer = wordIndexWriter(brands);
  for (const p of products) writer.add(p);
  assert.equal(adoptWordIndex(products, brands, { ...writer.pack(), count: writer.count }), true);
  assert.equal(shown(), before);
  adoptWordIndex(products, brands, null);
});

test("the page's searches use the worker's index and find exactly what they found without it", () => {
  const searches = ["shea butter", "red dress", "candl", "keyring", "lipstik", "zzqx shea", "gold hoop earrings for women", "a"];
  const run = () => searches.map((q) => {
    const found = searchWithGuesses(products, brands, { q, sort: "featured" });
    return [found.result.map((p) => p.id), found.showing, found.guesses];
  });
  adoptWordIndex(products, brands, null);
  assert.equal(adoptedWordIndex(), null);
  const before = run();
  const writer = wordIndexWriter(brands);
  for (const p of products) writer.add(p);
  const packed = { ...writer.pack(), count: writer.count };
  // An index for a list of another length is positions into the wrong list.
  assert.equal(adoptWordIndex(products.slice(1), brands, packed), false);
  assert.equal(adoptedWordIndex(), null);
  assert.equal(adoptWordIndex(products, brands, packed), true);
  const marks = pageCandidateMarks(products, brands, searchScorer("shea butter", brands).wordings);
  assert.ok(marks.reduce((a, b) => a + b, 0) < products.length / 20, "a search scores a small part of the list");
  assert.equal(pageCandidateMarks(products.slice(), brands, searchScorer("shea butter", brands).wordings), null, "another list gets no index");
  const started = performance.now();
  assert.deepEqual(run(), before);
  const indexed = performance.now() - started;
  // New department names (a new catalog) retire the index rather than trust it.
  setSearchCategories(querySource().categories ?? []);
  assert.equal(pageCandidateMarks(products, brands, searchScorer("shea butter", brands).wordings), null);
  assert.deepEqual(filterProducts(products, brands, { q: "shea butter" }).map((p) => p.id), before[0][0]);
  adoptWordIndex(products, brands, null);
  assert.ok(indexed < 10_000);
});
