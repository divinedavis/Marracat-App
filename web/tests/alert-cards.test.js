import { test } from "node:test";
import assert from "node:assert/strict";
import { small, fit, MAX_BYTES, dropPush, salePush, restockPush, digestPush, digestRow, sizeState } from "../server/alert-cards.js";

const p = (id, price, extra = {}) => ({ id, brand: "tel", title: `Bag ${id}`, price, currency: "USD", available: true,
  images: [`https://cdn.shopify.com/s/files/${id}.jpg?v=1`], ...extra });

test("photos are https only, Shopify ones at notification size", () => {
  assert.equal(small("https://cdn.shopify.com/a.jpg?v=2"), "https://cdn.shopify.com/a.jpg?v=2&width=400");
  assert.equal(small("https://example.com/a.jpg"), "https://example.com/a.jpg");
  assert.equal(small("http://cdn.shopify.com/a.jpg"), null);
  assert.equal(small("javascript:alert(1)"), null);
  assert.equal(small(undefined), null);
});

test("a new drop: three products, the brand thread, and the old brand field", () => {
  const push = dropPush("Telfar", "tel", [p("a", 148), p("b", 195), p("c", 78), p("d", 10)]);
  assert.equal(push.aps.category, "MC_DROP");
  assert.equal(push.aps["thread-id"], "brand-tel");
  assert.equal(push.card.items.length, 3);
  assert.equal(push.card.items[0].p, "$148");
  assert.equal(push.brandID, "tel");
  assert.equal(push.card.open, "marracat://brand/tel");
  const one = dropPush("Telfar", "tel", [p("a", 148)]);
  assert.equal(one.productID, "a");
  assert.equal(one.card.open, "marracat://product/a");
});

test("a sale shows its biggest markdowns first, with the % off", () => {
  const push = salePush("Fenty Beauty", "tel", 42, [p("a", 33, { compare_at: 36 }), p("b", 190, { compare_at: 284 }), p("c", 5), p("x", 1, { brand: "other", compare_at: 9 })]);
  assert.deepEqual(push.card.items.map((i) => [i.id, i.badge]), [["b", "−33%"], ["a", "−8%"]]);
  assert.equal(push.card.s, "42 items marked down · up to 33% off");
});

test("back in stock names the size that was watched", () => {
  const push = restockPush(p("a", 195), "Telfar", 991);
  assert.equal(push.card.vid, "991");
  assert.equal(push.aps.alert.body, "Bag a is back in stock at Telfar");
  assert.equal(restockPush(p("a", 195), "Telfar").card.vid, undefined, "no variant: no field");
});

test("sizes come from a Size option, and one left names its variant", () => {
  assert.equal(sizeState(null), null);
  assert.equal(sizeState({ options: ["Color"], variants: [{ option1: "Red" }, { option1: "Blue" }] }), null, "not sizes");
  const s = sizeState({ options: [{ name: "Color" }, { name: "Size" }], variants: [
    { id: 1, option1: "Red", option2: "S", available: false }, { id: 2, option1: "Blue", option2: "S", available: false },
    { id: 3, option1: "Red", option2: "M", available: true }] });
  assert.deepEqual(s, { sizes: [{ l: "S", a: false }, { l: "M", a: true }], left: 1, size: "M", variant: 3 });
});

test("a push that would pass 4 KB loses items, then its card, never its text", () => {
  const long = Array.from({ length: 30 }, (_, i) => p(`id-${i}-${"x".repeat(80)}`, 10, { title: "t".repeat(200) }));
  const push = dropPush("Telfar", "tel", long);
  assert.ok(Buffer.byteLength(JSON.stringify(push)) <= MAX_BYTES);
  const huge = fit({ aps: { alert: { title: "a", body: "b" }, "mutable-content": 1 }, card: { k: "drop", t: "x".repeat(5000), items: [] } });
  assert.equal(huge.card, undefined);
  assert.equal(huge.aps["mutable-content"], undefined);
  assert.equal(huge.aps.alert.title, "a");
});

test("the digest: a row per held-back alert, and a summary", () => {
  const rows = [digestRow({ k: "price", s: "Hanifa · you're watching its price", pct: "−15%", items: [{ t: "Dress" }], open: "marracat://product/a" }),
    digestRow({ k: "sale", t: "Fenty Beauty sale", s: "42 items marked down · up to 33% off" }),
    digestRow({ k: "drop", t: "New from Fear of God", items: [{ t: "Polo" }] })];
  assert.deepEqual(rows.map((r) => [r.b, r.st]), [["Hanifa", "−15%"], ["Fenty Beauty", "Sale"], ["Fear of God", "New"]]);
  assert.equal(digestRow({ k: "restock" }), null, "restocks never wait");
  const push = digestPush(rows);
  assert.equal(push.card.t, "3 updates today");
  assert.equal(push.card.s, "Price drops, sales and new drops");
  assert.equal(push.card.open, "marracat://product/a");
  assert.equal(push.card.rows[0].kind, undefined, "the app only needs the drawing fields");
});
