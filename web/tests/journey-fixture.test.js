// Every Playwright journey takes `test` from tests/browser/fixtures.js, which
// keeps analytics posts off the server, so a live run never counts as visitors.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

const dir = new URL("./browser/", import.meta.url);

test("no browser spec imports test straight from @playwright/test", () => {
  const specs = readdirSync(dir).filter((f) => f.endsWith(".spec.js"));
  assert.ok(specs.length > 10);
  for (const f of specs) {
    const src = readFileSync(new URL(f, dir), "utf8");
    assert.doesNotMatch(src, /from ["']@playwright\/test["']/, f);
    assert.match(src, /from ["']\.\/fixtures\.js["']/, f);
  }
});
