// Storefront credentials stay on the server. Only publish connection readiness.
export function createShopifyConnection(env = process.env, fetcher = fetch) {
  const domain = env.SHOPIFY_STORE_DOMAIN || "";
  const token = env.SHOPIFY_STOREFRONT_TOKEN || "";
  const version = env.SHOPIFY_API_VERSION || "2026-07";
  const configured = Boolean(domain && token);
  if (
    configured &&
    (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(domain) ||
      !/^\d{4}-(01|04|07|10)$/.test(version))
  )
    throw Error("Invalid Shopify configuration");
  let cached,
    expires = 0,
    pending;
  async function status() {
    if (!configured) return { connected: false, hasPublishedProducts: false };
    if (cached && Date.now() < expires) return cached;
    if (pending) return pending;
    pending = (async () => {
      try {
        const response = await fetcher(
          `https://${domain}/api/${version}/graphql.json`,
          {
            method: "POST",
            redirect: "error",
            headers: {
              "Content-Type": "application/json",
              "Shopify-Storefront-Private-Token": token,
            },
            body: JSON.stringify({
              query: "{ shop { name } products(first: 1) { nodes { id } } }",
            }),
            signal: AbortSignal.timeout(8000),
          },
        );
        if (!response.ok) throw Error("Shopify unavailable");
        const result = await response.json();
        if (
          result.errors?.length ||
          typeof result.data?.shop?.name !== "string" ||
          !Array.isArray(result.data?.products?.nodes)
        )
          throw Error("Invalid Shopify response");
        cached = {
          connected: true,
          hasPublishedProducts: result.data.products.nodes.length > 0,
        };
        expires = Date.now() + 60_000;
      } catch {
        // Upstream errors may contain credentials or request details; never forward them.
        cached = { connected: false, hasPublishedProducts: false };
        expires = Date.now() + 10_000;
      }
      return cached;
    })();
    try {
      return await pending;
    } finally {
      pending = null;
    }
  }
  return { status };
}

export function shopifyRoutes(app) {
  const connection = createShopifyConnection();
  app.get("/api/commerce/status", async (_, res) => {
    res.set("Cache-Control", "no-store");
    res.json(await connection.status());
  });
}
