import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

// 2026-11-26: a push sat for an hour and a half inside brand-claims.test.js.
// Its server listened on every address (`listen(0)`), the system handed it a
// port another program already held on 127.0.0.1 alone, and the test's
// requests to 127.0.0.1 went to that program, which never answered. A server
// bound to 127.0.0.1 is only ever given a port that is free there.
test("every test server listens on the loopback address, not on every address", () => {
  const loose = [];
  for (const name of fs.readdirSync(here).filter((n) => n.endsWith(".test.js"))) {
    if (name === path.basename(fileURLToPath(import.meta.url))) continue;
    fs.readFileSync(path.join(here, name), "utf8").split("\n").forEach((line, i) => {
      for (const call of line.matchAll(/\.listen\(\s*([^)]*)\)/g)) {
        const args = call[1].split(",").map((a) => a.trim()).filter(Boolean);
        if (args[0] !== "0") continue;
        if (!/^["']127\.0\.0\.1["']$/.test(args[1] || "")) loose.push(`${name}:${i + 1}`);
      }
    });
  }
  assert.deepEqual(loose, [], "give these a host: .listen(0, \"127.0.0.1\")");
});

// The first repair of the above made it worse for a moment: a server given a
// host is not listening yet on the next line, the tests threw before closing
// it, and the open server kept a finished test file from ever exiting. A time
// limit ends a test that waits forever; --test-force-exit ends a file whose
// tests are done but which still holds something open.
test("a hung test or a leftover server fails the run instead of holding it open", () => {
  const scripts = JSON.parse(fs.readFileSync(path.join(here, "..", "package.json"), "utf8")).scripts;
  const limit = Number((scripts.test.match(/--test-timeout=(\d+)/) || [])[1]);
  assert.ok(limit >= 60_000 && limit <= 600_000, `npm test needs a per-test time limit, found ${scripts.test}`);
  assert.match(scripts.test, /--test-force-exit\b/);
});
