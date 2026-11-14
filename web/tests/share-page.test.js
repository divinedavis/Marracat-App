import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setCatalog, shareCard } from "../server/catalog.js";
import { sharePage } from "../server/share-page.js";

const catalog = JSON.parse(readFileSync(new URL("../../Marracat/Resources/catalog.json", import.meta.url)));
const shell = readFileSync(new URL("../index.html", import.meta.url), "utf8");

test("a shared product link previews that product's photo, name and brand", () => {
  setCatalog(catalog);
  const product = catalog.products.find((p) => p.images?.length);
  const brand = catalog.brands.find((b) => b.id === product.brand);
  const html = sharePage(shell, shareCard(product.id));
  assert.match(html, /<meta property="og:image" content="https:\/\//);
  assert.ok(html.includes(`property="og:title"`));
  const title = html.match(/property="og:title" content="([^"]*)"/)[1];
  assert.ok(title.includes(brand.name.replace(/&/g, "&amp;").replace(/'/g, "&#39;").replace(/"/g, "&quot;")), title);
  assert.equal((html.match(/<title>/g) || []).length, 1);
  assert.ok(html.includes(`<link rel="canonical" href="https://marracat.com/p/`));
});

test("unknown products fall back to the site card, and titles are escaped", () => {
  assert.equal(sharePage(shell, null), shell);
  const html = sharePage(shell, { id: "x", title: `<script>"hi"</script>`, brand: "A&B", image: "javascript:alert(1)" });
  assert.ok(!html.includes("<script>\"hi\""));
  assert.ok(!html.includes("javascript:"));
  assert.ok(html.includes("A&amp;B"));
});

test("marracat.com/app previews our iPhone screenshot, then forwards to the App Store", async () => {
  const { appSharePage } = await import("../server/share-page.js");
  const html = appSharePage("https://apps.apple.com/us/app/marracat/id6810905687");
  assert.match(html, /og:image" content="https:\/\/marracat\.com\/app-preview\.jpg"/);
  assert.match(html, /og:description" content="Discover your next favorite"/);
  assert.match(html, /<script src="\/app-redirect\.js" defer><\/script>/, "the redirect is a script, which preview crawlers don't run");
  assert.match(html, /data-app-store href="https:\/\/apps\.apple\.com\/us\/app\/marracat\/id6810905687"/);
  assert.doesNotMatch(html, /http-equiv="refresh"/, "a meta refresh would send crawlers to Apple's card");
});
