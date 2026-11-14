import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("the UCP agent profile is valid and declares checkout capabilities", () => {
  const profile = JSON.parse(readFileSync(new URL("../server/ucp-profile.json", import.meta.url), "utf8"));
  assert.equal(profile.ucp.version, "2026-08-25");
  assert.equal(profile.ucp.services["dev.ucp.shopping"][0].transport, "mcp");
  for (const cap of ["dev.ucp.shopping.checkout", "dev.ucp.shopping.cart", "dev.ucp.shopping.fulfillment"])
    assert.ok(profile.ucp.capabilities[cap]?.length, cap);
  assert.deepEqual(profile.ucp.payment_handlers, {});
});
