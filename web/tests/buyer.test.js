import { test } from "node:test";
import assert from "node:assert/strict";
import { buyerFromAccount } from "../src/buyer.js";

// A signed-in shopper's checkout form starts with their name and email.
test("an account fills the buyer's name and email", () => {
  assert.deepEqual(buyerFromAccount({ name: "Divine J Davis", email: "d@example.com" }),
    { firstName: "Divine", lastName: "J Davis", email: "d@example.com" });
});

test("a one-word name, a relay email and no account", () => {
  assert.deepEqual(buyerFromAccount({ name: "Divine", email: "x1@privaterelay.appleid.com" }),
    { firstName: "Divine", lastName: "", email: "x1@privaterelay.appleid.com" });
  assert.deepEqual(buyerFromAccount(null), { firstName: "", lastName: "", email: "" });
  assert.deepEqual(buyerFromAccount({ name: "  ", email: "not-an-email" }), { firstName: "", lastName: "", email: "" });
});
