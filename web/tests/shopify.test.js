import { test } from "node:test";
import assert from "node:assert/strict";
import { createShopifyConnection } from "../server/shopify.js";
const env = {
  SHOPIFY_STORE_DOMAIN: "test-shop.myshopify.com",
  SHOPIFY_STOREFRONT_TOKEN: "test-private-token",
};
test("Shopify connection uses server credentials and coalesces checks without publishing secrets", async () => {
  let requests = 0;
  const connection = createShopifyConnection(env, async (url, options) => {
    requests++;
    assert.equal(
      url,
      "https://test-shop.myshopify.com/api/2026-07/graphql.json",
    );
    assert.equal(
      options.headers["Shopify-Storefront-Private-Token"],
      env.SHOPIFY_STOREFRONT_TOKEN,
    );
    assert.equal(options.redirect, "error");
    return Response.json({
      data: { shop: { name: "Marracat" }, products: { nodes: [] } },
    });
  });
  const results = await Promise.all([connection.status(), connection.status()]);
  assert.deepEqual(results[0], {
    connected: true,
    hasPublishedProducts: false,
  });
  assert.deepEqual(results[1], results[0]);
  assert.deepEqual(await connection.status(), results[0]);
  assert.equal(requests, 1);
});
test("disabled or failed Shopify connections do not leak upstream details or imply readiness", async () => {
  const offline = { connected: false, hasPublishedProducts: false };
  assert.deepEqual(
    await createShopifyConnection({}, () => {
      throw Error("Unexpected request");
    }).status(),
    offline,
  );
  for (const fetcher of [
    async () => {
      throw Error(env.SHOPIFY_STOREFRONT_TOKEN);
    },
    async () => new Response("Unauthorized", { status: 401 }),
    async () =>
      Response.json({ errors: [{ message: env.SHOPIFY_STOREFRONT_TOKEN }] }),
    async () => Response.json({ data: { shop: { name: "Marracat" } } }),
  ])
    assert.deepEqual(
      await createShopifyConnection(env, fetcher).status(),
      offline,
    );
});
test("Shopify connection accepts published products and restricts credential destinations", async () => {
  const connection = createShopifyConnection(env, async () =>
    Response.json({
      data: {
        shop: { name: "Marracat" },
        products: { nodes: [{ id: "gid://shopify/Product/1" }] },
      },
    }),
  );
  assert.deepEqual(await connection.status(), {
    connected: true,
    hasPublishedProducts: true,
  });
  for (const domain of [
    "evil.com",
    "shop.myshopify.com.evil.com",
    "shop.myshopify.com/path",
    "https://shop.myshopify.com",
  ])
    assert.throws(() =>
      createShopifyConnection({ ...env, SHOPIFY_STORE_DOMAIN: domain }),
    );
});
