import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// Public pages give the marracat.com aliases, never the owner's personal
// address (owner created support@/privacy@ etc. on 2026-10-09).
const read = (f) => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8");

test("support and privacy pages use the marracat.com aliases", () => {
  const main = read("main.jsx"), privacy = read("PrivacyPolicy.jsx");
  assert.match(main, /mailto:support@marracat\.com/);
  assert.match(main, /mailto:privacy@marracat\.com/);
  assert.match(privacy, /const EMAIL = "privacy@marracat\.com"/);
  for (const src of [main, privacy]) assert.doesNotMatch(src, /mailto:[^"]*gmail\.com/);
});

test("the app's delete-account text gives privacy@, not a personal address", () => {
  const panel = readFileSync(new URL("../../Marracat/Views/AccountPanel.swift", import.meta.url), "utf8");
  assert.match(panel, /email privacy@marracat\.com\./);
  assert.doesNotMatch(panel, /gmail\.com/);
});

// Siri and Spotlight (2026-10-14): the app indexes the shopper's saves, follows
// and recent views on the iPhone; both privacy texts must say so, and that it
// leaves with sign-out.
test("the privacy texts describe the on-device Spotlight index", () => {
  const privacy = read("PrivacyPolicy.jsx").replace(/\s+/g, " ");
  const panel = readFileSync(new URL("../../Marracat/Views/AccountPanel.swift", import.meta.url), "utf8");
  for (const text of [privacy, panel]) {
    assert.match(text, /Spotlight and Siri/);
    assert.match(text, /nothing from it is sent to Marracat/);
    assert.match(text, /deleting your account removes your items from it/);
  }
});
