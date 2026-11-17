// Shopify's Checkout Kit on the website (src/checkoutKit.js, 2026-11-15):
// which brand checkout links open in its window, and which keep the usual link.
import { test } from "node:test";
import assert from "node:assert/strict";
import { kitCheckoutURL, openCheckoutKit } from "../src/checkoutKit.js";

const here = "https://marracat.com/cart";
const shopify = { id: "gently-soap", domain: "gentlysoap.com" };

test("a Shopify brand's cart link or UCP checkout link opens in Checkout Kit", () => {
  assert.equal(kitCheckoutURL(shopify, "https://gentlysoap.com/cart/123:1,456:2?currency=USD", here),
    "https://gentlysoap.com/cart/123:1,456:2?currency=USD");
  assert.equal(kitCheckoutURL({ ...shopify, platform: "shopify" }, "https://gentlysoap.com/cart/c/abc?key=k", here),
    "https://gentlysoap.com/cart/c/abc?key=k");
  assert.equal(kitCheckoutURL(shopify, "https://karbon.myshopify.com/checkouts/cn/xyz", here),
    "https://karbon.myshopify.com/checkouts/cn/xyz");
});

test("other links keep opening the usual way", () => {
  // Big Cartel and Swell go through our own /go/ hand-off.
  assert.equal(kitCheckoutURL({ ...shopify, platform: "bigcartel" }, "/go/bigcartel?brand=x&items=1:2:1", here), null);
  assert.equal(kitCheckoutURL({ ...shopify, platform: "swell" }, "https://yeezy.com/checkout/abc", here), null);
  assert.equal(kitCheckoutURL({ ...shopify, platform: "woocommerce" }, "https://shop.example/cart/1:1", here), null);
  // Not a checkout: a product page, our own site, plain http, junk.
  assert.equal(kitCheckoutURL(shopify, "https://gentlysoap.com/products/bar", here), null);
  assert.equal(kitCheckoutURL(shopify, "/cart/1:1", here), null);
  assert.equal(kitCheckoutURL(shopify, "http://gentlysoap.com/cart/1:1", here), null);
  assert.equal(kitCheckoutURL(shopify, "javascript:alert(1)", here), null);
  assert.equal(kitCheckoutURL(null, "https://gentlysoap.com/cart/1:1", here), null);
  assert.equal(kitCheckoutURL(shopify, null, here), null);
});

test("without a browser (or before the component loads) nothing opens", () => {
  assert.equal(openCheckoutKit(shopify, "https://gentlysoap.com/cart/1:1"), false);
});
