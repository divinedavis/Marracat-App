// The page's catalog worker (owner, 2026-11-10: "background threads" and
// "data kept on the device"). Off the main thread it:
//
//   - reads the catalog as lines (src/catalog-format.js), from the copy kept
//     on this device when there is a recent one, otherwise from the network,
//     and hands each line to the page as it comes;
//   - keeps a compressed copy on the device (Cache Storage, ~13 MB) for the
//     next visit, and refreshes it in the background when the server has a
//     newer catalog;
//   - builds the word index search uses (src/catalog.js) and hands it over.
//
// Messages in:  { type: "open", url, maxAgeMs }   load: the device first, else the network
// Messages out: { type: "head", head, from }      a catalog starts ("device" | "network")
//               { type: "products", json }        one line: a JSON array of products
//               { type: "done", from, count }     every line sent
//               { type: "index", words, starts, postings, count }
//               { type: "error" }                 nothing could be loaded
// A second "head" means start over: what came before it is thrown away.
import { setSearchCategories, wordIndexWriter } from "./catalog.js";
import { CHUNK, lineSplitter, readHead } from "./catalog-format.js";

const CACHE = "marracat-catalog-v1";
const KEY = "/__device/catalog-lines";
let url = "/api/catalog?v=5&lines=1";
let maxAgeMs = 12 * 60 * 60 * 1000;
let delivered = false, fetching = false;

const post = (message, transfer) => self.postMessage(message, transfer || []);
const canKeep = () => typeof caches !== "undefined" && typeof CompressionStream !== "undefined" && typeof DecompressionStream !== "undefined";

/// Reads a body of lines, calling back as they complete. `onBytes` sees the
/// raw bytes too (the device copy is made from them). Returns the head, or
/// null when the body was not a catalog in lines.
async function readLines(body, { onHead, onLine, onBytes }) {
  const reader = body.getReader(), decoder = new TextDecoder(), split = lineSplitter();
  let head = null, first = true, whole = "";
  const take = (line) => {
    if (first) {
      first = false;
      head = readHead(line);
      if (head) return onHead(head);
    }
    if (head) onLine(line);
    else whole += line + "\n"; // one JSON document after all: read it at the end
  };
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    if (onBytes) await onBytes(value);
    for (const line of split.push(decoder.decode(value, { stream: true }))) take(line);
  }
  const tail = split.push(decoder.decode()).concat(split.rest() ? [split.rest()] : []);
  for (const line of tail) take(line);
  return head ? { head } : { whole };
}

/// Sends a catalog to the page as it is read and builds the index from it.
function deliverer(from) {
  let writer = null, count = 0, expected = 0;
  return {
    head(head) {
      const { format, count: n, ...rest } = head;
      expected = n;
      count = 0;
      setSearchCategories(rest.categories);
      writer = wordIndexWriter(rest.brands);
      post({ type: "head", head: rest, count: n, from });
    },
    line(json) {
      post({ type: "products", json });
      for (const p of JSON.parse(json)) writer.add(p);
      count = writer.count;
    },
    finish() {
      if (!writer || count !== expected) return false;
      post({ type: "done", from, count });
      const { words, starts, postings } = writer.pack();
      post({ type: "index", words, starts, postings, count }, [starts.buffer, postings.buffer]);
      writer = null;
      return true;
    },
  };
}

/// A whole-document catalog (an old server, or a test's stand-in): chunked here.
function deliverWhole(text, out) {
  const { products, ...head } = JSON.parse(text);
  if (!Array.isArray(products) || !Array.isArray(head.brands)) return false;
  out.head({ format: 1, count: products.length, ...head });
  for (let i = 0; i < products.length; i += CHUNK) out.line(JSON.stringify(products.slice(i, i + CHUNK)));
  return out.finish();
}

async function kept() {
  if (!canKeep()) return null;
  const cache = await caches.open(CACHE);
  const response = await cache.match(KEY);
  if (!response) return null;
  return { response, etag: response.headers.get("x-etag") || "", storedAt: Number(response.headers.get("x-stored-at")) || 0, source: response.headers.get("x-source") || "" };
}

/// A sink that compresses what it is given into the device copy. write()
/// waits when the compressor falls behind, so nothing piles up in memory.
async function keeper(etag) {
  if (!canKeep()) return null;
  const cache = await caches.open(CACHE);
  const pipe = new TransformStream(undefined, new ByteLengthQueuingStrategy({ highWaterMark: 4 << 20 }));
  const writer = pipe.writable.getWriter();
  const put = cache.put(KEY, new Response(pipe.readable.pipeThrough(new CompressionStream("gzip")), {
    headers: { "content-type": "application/octet-stream", "x-etag": etag, "x-stored-at": String(Date.now()), "x-source": url },
  })).then(() => true, () => false);
  return {
    async write(bytes) {
      if (writer.desiredSize <= 0) await writer.ready;
      writer.write(bytes).catch(() => {});
    },
    async close(ok) {
      try {
        if (ok) await writer.close();
        else await writer.abort();
      } catch {
        /* already errored */
      }
      // A partial or failed copy must not be read back next visit.
      if (!(await put) || !ok) await cache.delete(KEY).catch(() => {});
    },
  };
}

async function fromDevice(copy) {
  const out = deliverer("device");
  try {
    const body = copy.response.body.pipeThrough(new DecompressionStream("gzip"));
    const read = await readLines(body, { onHead: out.head, onLine: out.line });
    if (read.head && out.finish()) return true;
  } catch {
    /* a damaged copy: fall through */
  }
  await (await caches.open(CACHE)).delete(KEY).catch(() => {});
  return false;
}

/// Downloads the catalog. `deliver`: hand it to the page (otherwise it only
/// replaces the device copy, for next time). `etag`: only if it has changed.
async function fromNetwork({ deliver, etag = "" }) {
  const response = await fetch(url, etag ? { headers: { "If-None-Match": etag } } : { priority: "low" });
  if (response.status === 304) return "same";
  if (!response.ok || !response.body) throw Error("catalog " + response.status);
  const out = deliver ? deliverer("network") : null;
  const keep = await keeper(response.headers.get("etag") || "").catch(() => null);
  let ok = false, lines = false;
  try {
    const read = await readLines(response.body, {
      onHead: (head) => { lines = true; out?.head(head); },
      onLine: (line) => out?.line(line),
      onBytes: keep ? (bytes) => keep.write(bytes) : null,
    });
    ok = read.head ? (out ? out.finish() : true) : out ? deliverWhole(read.whole, out) : false;
  } finally {
    // Only a catalog in lines is kept: that is what fromDevice reads.
    await keep?.close(ok && lines);
  }
  if (!ok) throw Error("catalog unreadable");
  return "new";
}

async function open() {
  const copy = await kept().catch(() => null);
  const fresh = copy && copy.source === url && Date.now() - copy.storedAt <= maxAgeMs;
  if (fresh && (await fromDevice(copy))) {
    delivered = true;
    // For next time: fetch a newer catalog if there is one. Not handed to the
    // page; swapping every product under a shopper mid-visit helps nobody.
    fromNetwork({ deliver: false, etag: copy.etag }).catch(() => {});
    return;
  }
  await download();
}

async function download() {
  if (delivered || fetching) return;
  fetching = true;
  try {
    await fromNetwork({ deliver: true });
    delivered = true;
  } catch {
    // Offline, or the server is down: an old copy beats an empty shop.
    const copy = await kept().catch(() => null);
    if (copy && copy.source === url && (await fromDevice(copy))) delivered = true;
    else post({ type: "error" });
  } finally {
    fetching = false;
  }
}

self.onmessage = (e) => {
  const m = e.data || {};
  if (m.type === "open") {
    if (typeof m.url === "string") url = m.url;
    if (Number.isFinite(m.maxAgeMs)) maxAgeMs = m.maxAgeMs;
    open().catch(() => post({ type: "error" }));
  }
};
