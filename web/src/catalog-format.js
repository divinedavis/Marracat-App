// The catalog as lines (owner, 2026-11-10: parse it off the main thread and
// keep it on the device). One JSON document of 194,568 products has to be
// read whole before any of it can be used, and reading it froze the page.
// As lines it can be handled a piece at a time, as it arrives:
//
//   line 0      {"format":1,"count":N,"generated_at":…,"brands":[…],"categories":[…],…}
//   lines 1..k  [ up to CHUNK products ]
//
// The server writes it (server/catalog.js, /api/catalog?lines=1), the page's
// worker reads it from the network or from the copy kept on the device
// (src/catalog-worker.js), and the page parses one line per turn.
export const FORMAT = 1;
export const CHUNK = 2000;

/** A catalog ({ products, ...head }) as its lines. */
export function toLines(catalog, chunk = CHUNK) {
  const { products, ...head } = catalog;
  const lines = [JSON.stringify({ format: FORMAT, count: products.length, ...head })];
  for (let i = 0; i < products.length; i += chunk) lines.push(JSON.stringify(products.slice(i, i + chunk)));
  return lines;
}
export const linesText = (lines) => lines.join("\n") + "\n";

/** Is this first line the head of a catalog in lines? */
export function readHead(line) {
  try {
    const head = JSON.parse(line);
    return head && head.format === FORMAT && Number.isInteger(head.count) && Array.isArray(head.brands) ? head : null;
  } catch {
    return null;
  }
}

/** Text in, whole lines out: push(text) returns the lines it completed, and
 * rest() what is left when the text ends without a newline. */
export function lineSplitter() {
  let held = "";
  return {
    push(text) {
      held += text;
      const out = [];
      for (let at = held.indexOf("\n"), from = 0; ; at = held.indexOf("\n", from)) {
        if (at < 0) {
          held = held.slice(from);
          return out;
        }
        if (at > from) out.push(held.slice(from, at));
        from = at + 1;
      }
    },
    rest: () => held,
  };
}

/** Lines back to a catalog (the tests' and the fallback's reader). */
export function fromLines(lines) {
  const head = readHead(lines[0]);
  if (!head) return null;
  const { format, count, ...rest } = head;
  const products = [];
  for (const line of lines.slice(1)) for (const p of JSON.parse(line)) products.push(p);
  return products.length === count ? { ...rest, products } : null;
}
