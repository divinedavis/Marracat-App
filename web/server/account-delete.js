// Deleting an account: everything kept under it goes, in one transaction.
// The app's DELETE /api/mobile/account (mobile.js) and the website's
// DELETE /api/account (account-web.js) both end here.
//
// 2026-11-12: the app's deletion left rows behind (the phones' tracked orders
// and Live Activities, brand claims with their email address, brand-manager
// grants, the account id on visits and boosts), and an account made on the
// website with an email code or a passkey had no way to delete at all.
import { deleteSocialData } from "./social.js";
import { deleteRelayData } from "./relay.js";
import { deleteRestockData } from "./restock.js";
import { deleteDealAlertData } from "./deal-alerts.js";
import { deleteWebPushData } from "./web-push.js";
import { deletePasskeyData } from "./passkeys.js";
import { deleteCartData } from "./cart-sync.js";
import { deleteTrackedOrders } from "./order-tracking.js";
import { deleteIdentities } from "./identities.js";
import { deleteWebSessionData } from "./web-sessions.js";

const has = (db, table) => !!db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(table);

/// A monthly ad budget that is still being billed. Its Stripe subscription
/// would outlive the account, so deletion waits until it is canceled.
export function openBudget(db, userID) {
  if (!has(db, "boost_budgets")) return null;
  return db.prepare("SELECT brand_id FROM boost_budgets WHERE user_id=? AND status IN ('active','past_due')").get(userID)?.brand_id || null;
}

export function purgeAccount(db, userID) {
  db.transaction(() => {
    // The phones signed in to the account, read before their links go.
    const devices = has(db, "restock_links") ? db.prepare("SELECT device FROM restock_links WHERE user_id=?").all(userID).map((r) => r.device) : [];
    // Comments, profile, friends, devices and shares go too (App Store 5.1.1(v)).
    deleteSocialData(db, userID);
    // The order email address and everything received for it.
    if (has(db, "relay_addresses")) deleteRelayData(db, userID);
    // Orders those phones were tracking, and their Live Activities.
    for (const device of devices) {
      if (has(db, "tracked_orders")) deleteTrackedOrders(db, device);
      if (has(db, "live_activities")) db.prepare("DELETE FROM live_activities WHERE device=?").run(device);
    }
    // Restock alerts and the phones they were pushed to.
    if (has(db, "restock_watches")) deleteRestockData(db, userID);
    if (has(db, "price_watches")) deleteDealAlertData(db, userID);
    // The browsers the account turned notifications on in.
    if (has(db, "web_push_subs")) deleteWebPushData(db, userID);
    // Passkeys made on the website.
    if (has(db, "passkeys")) deletePasskeyData(db, userID);
    if (has(db, "carts")) deleteCartData(db, userID);
    // Brand management: the requests (they hold an email address) and the grants.
    for (const table of ["brand_claims", "brand_admins"]) if (has(db, table)) db.prepare(`DELETE FROM ${table} WHERE user_id=?`).run(userID);
    // Visit counts and payment records stay, without the account on them.
    if (has(db, "visits")) db.prepare("UPDATE visits SET user_id=NULL WHERE user_id=?").run(userID);
    if (has(db, "boosts")) db.prepare("UPDATE boosts SET user_id=NULL WHERE user_id=?").run(userID);
    if (has(db, "boost_budgets")) db.prepare("UPDATE boost_budgets SET user_id='deleted' WHERE user_id=?").run(userID);
    for (const table of ["mobile_sessions", "mobile_profiles", "mobile_operations", "mobile_accounts"]) if (has(db, table)) db.prepare(`DELETE FROM ${table} WHERE user_id=?`).run(userID);
    deleteWebSessionData(db, userID);
    deleteIdentities(db, userID);
    db.prepare("DELETE FROM users WHERE id=?").run(userID);
  })();
}
