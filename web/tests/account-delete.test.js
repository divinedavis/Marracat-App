import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import Database from "better-sqlite3";
import { accountWebRoutes, howToDelete } from "../server/account-web.js";
import { purgeAccount, openBudget } from "../server/account-delete.js";
import { installMobileSchema } from "../server/mobile.js";
import { installIdentitySchema } from "../server/identities.js";
import { installVisitSchema } from "../server/visits.js";
import { installRestockSchema } from "../server/restock.js";
import { installTrackingSchema } from "../server/order-tracking.js";
import { installLiveActivitySchema } from "../server/live-activity.js";
import { installBrandClaimSchema } from "../server/brand-claims.js";
import { installBudgetSchema } from "../server/boost-budgets.js";
import { installBoostSchema } from "../server/boosts.js";

const SECRET = "s".repeat(40);
function database() {
  const db = new Database(":memory:");
  db.exec("CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT, email TEXT, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)");
  installMobileSchema(db); installIdentitySchema(db); installVisitSchema(db); installRestockSchema(db);
  installTrackingSchema(db); installLiveActivitySchema(db); installBrandClaimSchema(db); installBoostSchema(db); installBudgetSchema(db);
  return db;
}
const count = (db, sql, ...a) => db.prepare(sql).get(...a).n;

// 2026-11-12: deleting an account left these rows behind.
test("deleting an account takes its phones' tracked orders, Live Activities and brand claims, and unnames it on visits and payments", () => {
  const db = database();
  for (const [id, email] of [["email:ann", "ann@example.test"], ["google:bob", "bob@example.test"]]) db.prepare("INSERT INTO users(id,name,email) VALUES(?,?,?)").run(id, "N", email);
  for (const [device, user] of [["d-ann", "email:ann"], ["d-bob", "google:bob"]]) {
    db.prepare("INSERT INTO restock_links(device,user_id,updated) VALUES(?,?,0)").run(device, user);
    db.prepare("INSERT INTO tracked_orders(device,brand_id,checkout_id,created,updated) VALUES(?,?,?,0,0)").run(device, "koba", `c-${device}`);
    db.prepare("INSERT INTO live_activities(device,updated) VALUES(?,0)").run(device);
    db.prepare("INSERT INTO visits(day,visitor,platform,user_id) VALUES('2026-11-12',?,'web',?)").run(`v-${device}`, user);
    db.prepare("INSERT INTO brand_claims(id,brand_id,user_id,method,email,created,expires) VALUES(?,?,?,?,?,0,0)").run(`cl-${device}`, "koba", user, "email", "owner@koba.example");
    db.prepare("INSERT INTO brand_admins(brand_id,user_id,role,via,created) VALUES('koba',?,'owner','domain-email',0)").run(user);
    db.prepare("INSERT INTO boosts(id,target,tier,amount_cents,user_id,created) VALUES(?,?,1,500,?,0)").run(`b-${device}`, "brand:koba", user);
    db.prepare("INSERT INTO boost_budgets(id,brand_id,user_id,target,tier,monthly_cents,status,created,updated) VALUES(?,?,?,?,1,5000,'canceled',0,0)").run(`bb-${device}`, "koba", user, "brand:koba");
  }
  purgeAccount(db, "email:ann");
  for (const [sql, arg] of [["SELECT COUNT(*) n FROM users WHERE id=?", "email:ann"], ["SELECT COUNT(*) n FROM tracked_orders WHERE device=?", "d-ann"],
    ["SELECT COUNT(*) n FROM live_activities WHERE device=?", "d-ann"], ["SELECT COUNT(*) n FROM restock_links WHERE user_id=?", "email:ann"],
    ["SELECT COUNT(*) n FROM brand_claims WHERE user_id=?", "email:ann"], ["SELECT COUNT(*) n FROM brand_admins WHERE user_id=?", "email:ann"],
    ["SELECT COUNT(*) n FROM visits WHERE user_id=?", "email:ann"], ["SELECT COUNT(*) n FROM boosts WHERE user_id=?", "email:ann"],
    ["SELECT COUNT(*) n FROM boost_budgets WHERE user_id=?", "email:ann"]]) assert.equal(count(db, sql, arg), 0, sql);
  assert.equal(count(db, "SELECT COUNT(*) n FROM visits"), 2, "the visit is still counted, without the account");
  assert.equal(count(db, "SELECT COUNT(*) n FROM boosts"), 2, "the payment record stays");
  // The other account is untouched.
  for (const sql of ["SELECT COUNT(*) n FROM users WHERE id='google:bob'", "SELECT COUNT(*) n FROM tracked_orders WHERE device='d-bob'",
    "SELECT COUNT(*) n FROM live_activities WHERE device='d-bob'", "SELECT COUNT(*) n FROM brand_admins WHERE user_id='google:bob'",
    "SELECT COUNT(*) n FROM visits WHERE user_id='google:bob'"]) assert.equal(count(db, sql), 1, sql);
});

test("how an account is deleted: an emailed code, the app for Apple sign-ins, after an ad budget is canceled", () => {
  const db = database();
  assert.deepEqual(howToDelete(db, { id: "email:ann", email: "ann@example.test" }), { how: "email", email: "ann@example.test" });
  assert.deepEqual(howToDelete(db, { id: "apple:001", email: "a@example.test" }), { how: "app" });
  db.prepare("INSERT INTO user_identities(identity,user_id,linked) VALUES('apple:002','google:bob',0)").run();
  assert.deepEqual(howToDelete(db, { id: "google:bob", email: "bob@example.test" }), { how: "app" }, "a Google account that also signs in with Apple");
  assert.deepEqual(howToDelete(db, { id: "passkey:x", email: null }), { how: "support" });
  db.prepare("INSERT INTO boost_budgets(id,brand_id,user_id,target,tier,monthly_cents,status,created,updated) VALUES('bb','koba','email:ann','brand:koba',1,5000,'active',0,0)").run();
  assert.equal(openBudget(db, "email:ann"), "koba");
  assert.deepEqual(howToDelete(db, { id: "email:ann", email: "ann@example.test" }), { how: "cancel-budget", brand: "koba" });
});

// 2026-11-12: an account made on the website with an email code had no way to delete.
test("the website deletes an account once the code emailed to it comes back", async (t) => {
  const db = database();
  db.prepare("INSERT INTO users(id,name,email) VALUES('email:ann','Ann','ann@example.test')").run();
  db.prepare("INSERT INTO users(id,name,email) VALUES('apple:001','Al','al@example.test')").run();
  const mails = [];
  const app = express();
  accountWebRoutes(app, db, { secret: SECRET, mailer: async (m) => mails.push(m),
    viewer: async (req) => (req.get("X-User") ? db.prepare("SELECT id,name,email FROM users WHERE id=?").get(req.get("X-User")) || null : null) });
  const s = app.listen(0, "127.0.0.1"); await new Promise((r) => s.once("listening", r));
  t.after(() => { s.close(); db.close(); });
  const call = (path, method, user, body) => fetch(`http://127.0.0.1:${s.address().port}/api/account${path}`, { method,
    headers: { "Content-Type": "application/json", ...(user ? { "X-User": user } : {}) }, body: body ? JSON.stringify(body) : undefined });
  assert.equal((await call("/delete", "GET")).status, 401);
  assert.equal((await call("/", "DELETE", null, { code: "000000" })).status, 401, "signed out");
  assert.deepEqual(await (await call("/delete", "GET", "email:ann")).json(), { how: "email", email: "ann@example.test" });
  assert.equal((await call("/delete/code", "POST", "apple:001")).status, 409, "an Apple account is deleted in the app");
  assert.equal((await call("/", "DELETE", "apple:001", { code: "123456" })).status, 409);
  assert.equal((await call("/", "DELETE", "email:ann", { code: "123456" })).status, 401, "no code was ever sent");
  assert.equal((await call("/delete/code", "POST", "email:ann")).status, 204);
  assert.equal(mails.length, 1);
  assert.equal(mails[0].to, "ann@example.test");
  const code = mails[0].subject.match(/^(\d{6}) is your Marracat account deletion code$/)[1];
  assert.equal((await call("/delete/code", "POST", "email:ann")).status, 429, "one code at a time");
  const wrong = code === "000000" ? "111111" : "000000";
  assert.equal((await call("/", "DELETE", "email:ann", { code: wrong })).status, 401);
  assert.equal(count(db, "SELECT COUNT(*) n FROM users WHERE id='email:ann'"), 1);
  assert.equal((await call("/", "DELETE", "email:ann", { code })).status, 204);
  assert.equal(count(db, "SELECT COUNT(*) n FROM users WHERE id='email:ann'"), 0);
  assert.equal(count(db, "SELECT COUNT(*) n FROM email_codes"), 0, "the spent code goes with the account");
  assert.equal(count(db, "SELECT COUNT(*) n FROM users"), 1, "nobody else's account");
  assert.equal((await call("/profile", "GET", "email:ann")).status, 401, "the session no longer names an account");
});

test("a sign-in code can't delete an account, and a deletion code can't sign in", async () => {
  const { issueCode, checkCode } = await import("../server/email-code.js");
  const db = database();
  const signIn = issueCode(db, "ann@example.test", { secret: SECRET }).code;
  assert.equal(checkCode(db, "delete:ann@example.test", signIn, { secret: SECRET }), false);
  const del = issueCode(db, "delete:ann@example.test", { secret: SECRET, code: "424242" }).code;
  assert.equal(checkCode(db, "ann@example.test", del, { secret: SECRET }), signIn === "424242");
});
