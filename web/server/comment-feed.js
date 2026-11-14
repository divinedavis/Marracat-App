// "What people are saying" on the home page (owner, 2026-10-10): the newest
// product comments, each with its product. Visitors who read comments opened
// two to three times as many products in the last two weeks' logs.
//
// Only what any stranger could already see on the product page, and less: a
// top-level comment that isn't deleted, isn't hidden (a report hides one at
// once until the owner reviews it), whose author has a profile and isn't
// suspended, and that still passes the language filter. A signed-in viewer
// never sees someone they blocked or who blocked them. At most one comment a
// product, newest first. The list is rebuilt at most once a minute.
import { refusal } from "./content-filter.js";

export const FEED_SIZE = 6;
const BODY_MAX = 240;
const CACHE_MS = 60_000;

export function recentComments(db, card, { limit = FEED_SIZE } = {}) {
  const rows = db.prepare(`SELECT c.id, c.product_id, c.user_id, c.body, c.created_at, p.handle, p.display_name
      FROM comments c JOIN profiles p ON p.user_id = c.user_id
      WHERE c.parent_id IS NULL AND c.deleted_at IS NULL AND c.hidden_at IS NULL AND c.user_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM user_flags f WHERE f.user_id = c.user_id AND f.suspended_at IS NOT NULL)
      ORDER BY c.created_at DESC LIMIT 200`).all();
  const out = [], products = new Set();
  for (const c of rows) {
    if (products.has(c.product_id) || refusal(c.body)) continue;
    const product = card(c.product_id);
    if (!product) continue; // no longer in the catalog
    products.add(c.product_id);
    const body = c.body.replace(/\s+/g, " ").trim();
    out.push({
      id: c.id,
      body: body.length > BODY_MAX ? body.slice(0, BODY_MAX - 1).trimEnd() + "…" : body,
      created_at: c.created_at,
      author: { handle: c.handle, name: c.display_name },
      author_id: c.user_id, // dropped before it leaves the server
      product: { id: product.id, title: product.title, brand: product.brand, image: product.image },
    });
    if (out.length >= limit * 3) break; // spare rows for viewers with blocks
  }
  return out;
}

export function commentFeedRoutes(app, db, { card, viewer = async () => null, now = () => Date.now() } = {}) {
  let cached = null, at = 0;
  app.get("/api/comments/recent", async (req, res) => {
    if (!cached || now() - at > CACHE_MS) {
      try {
        cached = recentComments(db, card);
      } catch {
        cached = []; // no social tables yet on a fresh database
      }
      at = now();
    }
    const me = await viewer(req).catch(() => null);
    const blocked = me
      ? new Set(db.prepare("SELECT blocked_id AS id FROM blocks WHERE user_id=? UNION SELECT user_id FROM blocks WHERE blocked_id=?")
        .all(me.id, me.id).map((r) => r.id))
      : new Set();
    const comments = cached.filter((c) => !blocked.has(c.author_id)).slice(0, FEED_SIZE)
      .map(({ author_id, ...c }) => c);
    // Personalised by blocks once someone signs in, so no browser or proxy
    // keeps a copy; the server-side minute cache above does the speeding up.
    res.set("Cache-Control", "no-store");
    res.json({ comments });
  });
}
