import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import Database from "better-sqlite3";
import { useProductDetails, productDetails, productRecord, HOME_HERO } from "../server/catalog.js";

// Deployed, the server keeps a slim list in memory and reads a product's full
// record from product-details.sqlite (scripts/split_server_catalog.py).
test("a product page's record comes from the details db when the server has one", (t) => {
  const file = path.join(mkdtempSync(path.join(tmpdir(), "details-")), "product-details.sqlite");
  const db = new Database(file);
  db.exec("CREATE TABLE product_details (id TEXT PRIMARY KEY, data TEXT NOT NULL)");
  const full = { ...productRecord(HOME_HERO), description: "From the details row. A independent label.", images: ["1.jpg", "2.jpg"] };
  db.prepare("INSERT INTO product_details VALUES(?,?)").run(HOME_HERO, JSON.stringify(full));
  db.close();
  t.after(() => useProductDetails(null));

  useProductDetails(file);
  const product = productDetails(HOME_HERO);
  assert.equal(product.description.startsWith("From the details row."), true);
  assert.deepEqual(product.images, ["1.jpg", "2.jpg"]);
  // The same website copy rules as before apply to the row.
  assert.ok(!/black[\s-]*owned/i.test(product.description), product.description);
  // An id the catalog doesn't carry is still a 404, whatever the db holds.
  assert.equal(productDetails("not-a-product"), undefined);
  useProductDetails(null);
  assert.equal(productDetails(HOME_HERO), productRecord(HOME_HERO), "without a db, the in-memory record");
});
