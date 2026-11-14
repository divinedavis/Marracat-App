import { test } from "node:test";
import assert from "node:assert/strict";
import { brandSharePage } from "../server/share-page.js";

// A shared brand link previews as the brand, replacing the site's own card.
test("brand share page carries the brand's Open Graph tags only", () => {
  const shell = '<html><head><title>Marracat</title><link rel="canonical" href="https://marracat.com/"/><meta property="og:title" content="Marracat"/><meta property="og:image" content="https://marracat.com/og-marracat.png"/><meta name="twitter:card" content="summary_large_image"/></head><body></body></html>';
  const out = brandSharePage(shell, { id: "therenaebrand", title: "The Renae Brand", tagline: "Earrings", image: "https://assets.bigcartel.com/x.jpg" });
  assert.match(out, /og:title" content="The Renae Brand on Marracat"/);
  assert.match(out, /og:image" content="https:\/\/assets\.bigcartel\.com\/x\.jpg"/);
  assert.match(out, /canonical" href="https:\/\/marracat\.com\/b\/therenaebrand"/);
  assert.equal((out.match(/og:image/g) || []).length, 1, "the site's own image is gone");
  assert.equal(brandSharePage(shell, null), shell);
});
