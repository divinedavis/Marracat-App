import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

// deploy.sh tars a fixed list of paths. On 2026-10-10 server/query.js imported
// ../src/catalog.js, which wasn't in the list: the new server couldn't start
// and the deploy rolled back. Every file the server imports must be shipped.
test("everything server/ imports from outside server/ is in the deploy bundle", () => {
  const deploy = readFileSync(new URL("../deploy.sh", import.meta.url), "utf8");
  const shipped = deploy.match(/tar -czf "\$bundle_path" ([^\n]+)/)[1].split(/\s+/);
  const covered = (p) => shipped.some((s) => p === s || p.startsWith(s + "/"));
  for (const f of readdirSync(new URL("../server/", import.meta.url)).filter((f) => f.endsWith(".js"))) {
    const src = readFileSync(new URL(`../server/${f}`, import.meta.url), "utf8");
    for (const [, rel] of src.matchAll(/from\s+["']\.\.\/([^"']+)["']/g))
      assert.ok(covered(rel), `server/${f} imports ../${rel}, which deploy.sh doesn't ship`);
  }
});

// A shipped src/ file's own imports must ship too: src/catalog.js reads
// src/search-synonyms.json (2026-10-10).
test("relative imports of shipped src/ files are in the deploy bundle", () => {
  const deploy = readFileSync(new URL("../deploy.sh", import.meta.url), "utf8");
  const shipped = deploy.match(/tar -czf "\$bundle_path" ([^\n]+)/)[1].split(/\s+/);
  for (const f of shipped.filter((s) => s.startsWith("src/") && s.endsWith(".js"))) {
    const src = readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
    for (const [, rel] of src.matchAll(/from\s+["']\.\/([^"']+)["']/g))
      assert.ok(shipped.includes(`src/${rel}`), `${f} imports ./${rel}, which deploy.sh doesn't ship`);
  }
});

// nginx serves marracat.com's static files from /var/www/marracat, and deploy.sh
// copies only listed extensions there. public/search-synonyms.json fell
// through to the SPA's index.html on 2026-10-11.
test("every file type in public/ is copied to the static root", () => {
  const deploy = readFileSync(new URL("../deploy.sh", import.meta.url), "utf8");
  const copied = new Set([...deploy.matchAll(/dist\/\*\.(\w+)/g)].map((m) => m[1]));
  for (const f of readdirSync(new URL("../public/", import.meta.url), { withFileTypes: true }).filter((d) => d.isFile())) {
    const ext = f.name.split(".").pop();
    assert.ok(copied.has(ext), `public/${f.name}: deploy.sh doesn't copy *.${ext} to /var/www/marracat`);
  }
});

test("a web deploy keeps the live catalog when this Mac's copy is older", () => {
  // 2026-10-15: shipping the Mac's older catalog with a code change dropped
  // the day's 22 new brands from marracat.com.
  const script = readFileSync(new URL("../deploy.sh", import.meta.url), "utf8");
  assert.match(script, /"\$local_generated" < "\$now_generated"/);
  assert.match(script, /cp -al \/opt\/marracat-web\/current\/server\/catalog-slim\.json \/opt\/marracat-web\/current\/server\/product-details\.sqlite server\//);
  assert.match(script, /SHIP_LOCAL_CATALOG/);
});

// The script and stylesheet are compressed once at deploy, not by nginx on
// every request at level 1 (2026-11-10). Either half alone does nothing:
// gzip_static without the .gz files serves level 1, the files without it sit unused.
test("assets ship precompressed and nginx serves the precompressed copy", () => {
  const deploy = readFileSync(new URL("../deploy.sh", import.meta.url), "utf8");
  const nginx = readFileSync(new URL("../nginx.conf", import.meta.url), "utf8");
  const gzip = deploy.indexOf('gzip -9 -k -n "$f"'), tar = deploy.indexOf('tar -czf "$bundle_path"');
  assert.ok(gzip > 0 && gzip < tar, "deploy.sh compresses dist/assets before bundling it");
  assert.match(nginx, /location \/assets\/ \{[^}]*gzip_static on;[^}]*\}/);
});

// What the browser can do before the page's script runs (2026-11-10): one
// multiplexed HTTP/2 connection instead of six HTTP/1.1 ones, and the
// connection to the host of nearly every product photo opened while the
// script and /api/home are still on their way.
// HTTP/3 (2026-11-11): both 443 blocks also listen for QUIC, reuseport once
// per address (nginx refuses a second), and the site advertises it.
test("the site is served over HTTP/2 and HTTP/3 and connects early to the photo host", () => {
  const nginx = readFileSync(new URL("../nginx.conf", import.meta.url), "utf8");
  const listens = [...nginx.matchAll(/^\s*listen [^;]*443[^;]*;/gm)].map((m) => m[0].trim());
  const tcp = listens.filter((l) => !/\bquic\b/.test(l)), quic = listens.filter((l) => /\bquic\b/.test(l));
  assert.ok(tcp.length >= 4 && tcp.every((l) => /\bssl http2;$/.test(l)), tcp.join(" | "));
  assert.equal(quic.length, tcp.length, `a QUIC listener beside each TLS one: ${quic.join(" | ")}`);
  assert.deepEqual(quic.filter((l) => /reuseport/.test(l)).map((l) => l.split(" ")[1]).sort(), ["443", "[::]:443"]);
  assert.match(nginx, /add_header Alt-Svc 'h3=":443"; ma=\d+' always;/);
  const shell = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  assert.match(shell, /<link rel="preconnect" href="https:\/\/cdn\.shopify\.com"\/>/);
});

// The service worker (public/sw.js, 2026-11-10). A stale copy keeps serving
// what it cached, so nginx must not let one be cached; and it must agree with
// the router about which paths are real server pages, or it would answer
// /auth or /app with the storefront.
test("the service worker is never cached and agrees with the router on server paths", () => {
  const nginx = readFileSync(new URL("../nginx.conf", import.meta.url), "utf8");
  assert.match(nginx, /location = \/sw\.js \{[^}]*expires -1;[^}]*\}/);
  const sw = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");
  const router = readFileSync(new URL("../src/router.js", import.meta.url), "utf8");
  const paths = (src) => src.match(/const SERVER_PATHS = (\/.+\/i);/)[1];
  assert.equal(paths(sw), paths(router));
  // It answers only what it is meant to: no /auth, no other /api path.
  assert.doesNotMatch(sw, /\/auth\//);
  assert.deepEqual([...sw.matchAll(/"\/api\/[a-z-]+"/g)].map((m) => m[0]), ['"/api/home"']);
  const shell = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  assert.match(shell, /<link rel="manifest" href="\/manifest\.json"\/>/);
  const manifest = JSON.parse(readFileSync(new URL("../public/manifest.json", import.meta.url), "utf8"));
  for (const icon of manifest.icons) assert.ok(readdirSync(new URL("../public/", import.meta.url)).includes(icon.src.slice(1)), icon.src);
});


// 2026-11-12: nginx drops the server's add_header lines in any location that
// has one of its own, so the catalog and model files went out without HSTS
// or nosniff.
test("every nginx location that sets a header repeats the security headers", () => {
  const nginx = readFileSync(new URL("../nginx.conf", import.meta.url), "utf8");
  const tls = nginx.slice(nginx.indexOf("ssl_certificate_key"));
  const blocks = [...tls.matchAll(/\n    location [^\n]*\{\n([\s\S]*?)\n    \}/g)].map((m) => m[0]).filter((b) => /^\s*add_header /m.test(b));
  assert.ok(blocks.length >= 3, "the catalog, delta and model locations");
  for (const b of blocks) {
    const name = b.trim().split("\n")[0];
    assert.match(b, /add_header Strict-Transport-Security "max-age=31536000" always;/, name);
    assert.match(b, /add_header X-Content-Type-Options nosniff always;/, name);
    assert.match(b, /add_header Referrer-Policy strict-origin-when-cross-origin always;/, name);
  }
});
