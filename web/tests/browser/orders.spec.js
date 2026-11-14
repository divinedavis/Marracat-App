import { test, expect } from "./fixtures.js";

// Your Orders and order details on the website (owner, 2026-10-11: rows open
// the order's details and shipments like the app; the list looks like Amazon's).
const APPLE = 978307200;
const ago = (days) => (Date.now() - days * 86400_000) / 1000 - APPLE;
const orders = [
  { id: "O-SHIPPED", brandID: "koba-skincare", date: ago(4), itemCount: 1, subtotal: 9.99, total: 9.99, currency: "USD",
    orderID: "gid://shopify/OrderIdentity/17374756274563", items: [{ title: "Le Discovery Set", quantity: 1 }] },
  { id: "O-NEW", brandID: "koba-skincare", date: ago(1), itemCount: 2, subtotal: 21.16, currency: "USD",
    items: [{ title: "Keep It Together Headband", quantity: 2 }] },
];
const updates = {
  events: [],
  tracked: [{ brandID: "koba-skincare", orderID: "gid://shopify/Order/17374756274563", state: "shipped", carrier: "USPS",
    trackingNumber: "9400111", statusPage: "https://koba.example/orders/status", created: Date.now() - 4 * 86400_000, updated: Date.now() - 2 * 86400_000 }],
};

async function signedIn(page) {
  await page.route("**/api/account/profile", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ profile: { checkouts: orders } }) }));
  await page.route("**/api/account/orders/updates", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(updates) }));
}

test("Your Orders lists each order as a card with its status and actions", async ({ page }) => {
  await signedIn(page);
  await page.goto("/orders");
  await expect(page.getByRole("heading", { name: "Your Orders" })).toBeVisible({ timeout: 60000 });
  const cards = page.locator(".order-box");
  await expect(cards).toHaveCount(2);
  const shipped = page.locator('.order-box[data-order="O-SHIPPED"]');
  await expect(shipped).toContainText("Order placed");
  await expect(shipped).toContainText("$9.99");
  await expect(shipped).toContainText("Order # 17374756274563");
  await expect(shipped.locator("[data-order-status]")).toContainText("Shipped");
  await expect(shipped.getByRole("link", { name: "Track package" })).toHaveAttribute("href", "https://koba.example/orders/status");
  // Search narrows the list; Not Yet Shipped shows only the unshipped one.
  await page.getByLabel("Search all orders").fill("headband");
  await page.getByRole("button", { name: "Search Orders" }).click();
  await expect(cards).toHaveCount(1);
  await page.goto("/orders?tab=unshipped");
  await expect(page.locator(".order-box")).toHaveCount(1);
  await expect(page.locator('.order-box[data-order="O-NEW"]')).toBeVisible();
});

test("an order opens its details: tracker, tracking number, history, items", async ({ page }) => {
  await signedIn(page);
  await page.goto("/orders");
  await page.locator('.order-box[data-order="O-SHIPPED"]').getByRole("link", { name: "View order details" }).first().click();
  await expect(page).toHaveURL(/\/order\?id=O-SHIPPED/);
  await expect(page.getByRole("heading", { name: "Order details" })).toBeVisible();
  await expect(page.locator("[data-order-status]")).toContainText("Shipped");
  await expect(page.locator(".order-tracker li.done")).toHaveCount(2);
  await expect(page.getByText("USPS tracking 9400111")).toBeVisible();
  await expect(page.locator("[data-order-history]")).toContainText("Shipped · USPS");
  await expect(page.locator(".order-items")).toContainText("Le Discovery Set");
  await page.getByRole("link", { name: "Your orders" }).click();
  await expect(page).toHaveURL(/\/orders$/);
});

test("signed out, the orders page asks to sign in", async ({ page }) => {
  await page.route("**/api/account/profile", (r) => r.fulfill({ status: 401, body: "{}" }));
  await page.route("**/api/account/orders/updates", (r) => r.fulfill({ status: 401, body: "{}" }));
  await page.goto("/orders");
  await expect(page.getByText("Sign in to see your orders.")).toBeVisible({ timeout: 60000 });
});

test("Your Orders doesn't wait for the full catalog; it fetches just the ordered products", async ({ page }) => {
  const withProducts = orders.map((o) => ({ ...o, productIDs: [o.id === "O-NEW" ? "test-headband" : "test-set"] }));
  await page.route("**/api/account/profile", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ profile: { checkouts: withProducts } }) }));
  await page.route("**/api/account/orders/updates", (r) => r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(updates) }));
  await page.route("**/api/catalog?**", () => {});   // never answers
  const asked = [];
  await page.route("**/api/products/**", (r) => {
    const id = decodeURIComponent(new URL(r.request().url()).pathname.split("/").pop());
    asked.push(id);
    r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ title: id, brand: "koba-skincare", available: true, price: 10, images: ["https://cdn.shopify.com/x.png"] }) });
  });
  await page.goto("/orders");
  await expect(page.locator(".order-box")).toHaveCount(2, { timeout: 8000 });
  await expect(page.locator(".order-box-thumb img")).toHaveCount(2);
  expect(asked.sort()).toEqual(["test-headband", "test-set"]);
});
