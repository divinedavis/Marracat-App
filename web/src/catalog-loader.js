// The page's side of the catalog worker (src/catalog-worker.js): start it,
// take the catalog a line at a time (each line is parsed in its own turn, so
// the page keeps answering taps while 194,568 products arrive), and adopt the
// search index it builds.
import { adoptWordIndex } from "./catalog.js";

let worker = null;
/// How long a worker may stay silent before the page loads the catalog itself.
export const SILENCE_MS = 10_000;

/// Takes the worker's messages and calls back with whole catalogs.
/// Exported for tests: it needs no worker, only the messages.
export function catalogAssembler({ onCatalog, onIndex = () => {}, onError = () => {} }) {
  let building = null, current = null;
  return (m) => {
    if (!m || typeof m !== "object") return;
    if (m.type === "head") building = { head: m.head, count: m.count, from: m.from, chunks: [], got: 0 };
    else if (m.type === "products" && building) {
      const chunk = JSON.parse(m.json);
      building.chunks.push(chunk);
      building.got += chunk.length;
    } else if (m.type === "done" && building) {
      const done = building;
      building = null;
      if (done.got !== done.count) return onError();
      current = { ...done.head, products: done.chunks.flat() };
      onCatalog(current, done.from);
    } else if (m.type === "index" && current) {
      // Positions into the list just handed over, and only that list.
      onIndex(adoptWordIndex(current.products, current.brands, m));
    } else if (m.type === "error") {
      building = null;
      onError();
    }
  };
}

/// Starts the worker once `gate` settles. False when this browser has no
/// module workers: the caller then loads the catalog on the page as before.
/// `onFallback` is called instead of `onError` when the worker itself failed
/// before handing anything over.
export function loadCatalogInWorker({ url, gate = Promise.resolve(), maxAgeMs, onCatalog, onIndex, onError, onFallback }) {
  if (typeof Worker === "undefined") return false;
  worker?.terminate();
  let mine, heard = false, handed = false, dropped = false;
  const drop = () => {
    if (dropped) return;
    dropped = true;
    mine?.terminate();
    if (worker === mine) worker = null;
    if (!handed) onFallback();
  };
  try {
    mine = worker = new Worker(new URL("./catalog-worker.js", import.meta.url), { type: "module" });
  } catch {
    return false;
  }
  const take = catalogAssembler({
    onCatalog: (c, from) => { handed = true; onCatalog(c, from); },
    onIndex,
    onError: () => { if (!handed) onError(); },
  });
  mine.onmessage = (e) => { heard = true; if (!dropped) take(e.data); };
  mine.onerror = drop;
  mine.onmessageerror = drop;
  gate.then(() => {
    if (dropped) return;
    mine.postMessage({ type: "open", url, maxAgeMs });
    setTimeout(() => { if (!heard) drop(); }, SILENCE_MS);
  });
  return true;
}
