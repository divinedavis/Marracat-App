import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

// marracat.com used to @import DM Sans and Manrope from Google Fonts, which
// sends every visitor's IP address to Google (LG Munich 3 O 17493/20 fined a
// site for exactly this under GDPR). The fonts are self-hosted since
// 2026-11-07 (src/fonts.css). Nothing the site serves may name a Google font
// host again: not the source, not the built bundle, not the CSP.
const web = fileURLToPath(new URL("..", import.meta.url));
const GOOGLE_FONT_HOST = /fonts\.googleapis\.com|fonts\.gstatic\.com|\bgstatic\.com/i;
const TEXT = /\.(css|html?|jsx?|mjs|cjs|json|svg|txt|xml|conf)$/i;

function* files(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name.startsWith(".")) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* files(p);
    else if (TEXT.test(name)) yield p;
  }
}

test("no web source, page, server file or build output names a Google font host", () => {
  const roots = ["src", "public", "server", "mail", "dist"].map((d) => join(web, d));
  const singles = ["index.html", "nginx.conf", "nginx-http.conf"].map((f) => join(web, f));
  const offenders = [];
  for (const f of [...roots.flatMap((r) => [...files(r)]), ...singles.filter(existsSync)]) {
    if (statSync(f).size > 20_000_000) continue; // catalog data, not markup
    const text = readFileSync(f, "utf8");
    if (GOOGLE_FONT_HOST.test(text)) offenders.push(f.slice(web.length));
  }
  assert.deepEqual(offenders, [], `Google font host referenced in: ${offenders.join(", ")}`);
});

test("the CSP allows fonts and styles from marracat.com only", () => {
  const conf = readFileSync(join(web, "nginx.conf"), "utf8");
  const csps = [...conf.matchAll(/Content-Security-Policy "([^"]+)"/g)].map((m) => m[1]);
  assert.ok(csps.length > 0, "nginx.conf sets a CSP");
  for (const csp of csps) {
    const directive = (name) => (csp.split(";").map((s) => s.trim()).find((s) => s.startsWith(name + " ")) || "");
    assert.equal(directive("font-src"), "font-src 'self'");
    assert.doesNotMatch(directive("style-src"), /https?:/);
  }
});

test("every self-hosted font file the stylesheet names exists and is woff2", () => {
  const css = readFileSync(join(web, "src/fonts.css"), "utf8");
  const faces = [...css.matchAll(/@font-face\s*\{([^}]+)\}/g)].map((m) => m[1]);
  const families = new Set();
  for (const face of faces) {
    const family = face.match(/font-family:\s*"([^"]+)"/)[1];
    families.add(family);
    assert.match(face, /font-display:\s*swap/, `${family} swaps in`);
    const url = face.match(/url\("\.\/(fonts\/[^"]+\.woff2)"\)/)[1];
    const bytes = readFileSync(join(web, "src", url));
    assert.equal(bytes.subarray(0, 4).toString("latin1"), "wOF2", `${url} is woff2`);
  }
  assert.deepEqual([...families].sort(), ["DM Sans", "Manrope"]);
  assert.equal(faces.length, 4, "latin and latin-ext for each family");
  assert.match(readFileSync(join(web, "src/style.css"), "utf8").split("\n")[0], /^@import "\.\/fonts\.css";$/);
});
