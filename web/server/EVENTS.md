# Marracat event catalog

One first-party analytics stream for the website and the iPhone app
(server/events.js, `POST /api/events`). This file is the source of truth for
event names and props. The app, the website and `events-report.js` all follow
it, and a test fails if an event in `SCHEMAS` is missing here.

## Sending

- **Endpoint:** `POST https://marracat.com/api/events`, JSON.
- **Body:** one event, or a batch `{"events": [ … ]}` of up to 50.
- **Event name:** `name` (the app) or `e` (the website).
- **Props:** top level, or nested under `props`.
- **Who is sending:**
  - **Website:** the body carries `id`, the random visitor id kept in localStorage (`marracat-visitor`). It may also carry `build`, a number.
  - **App:** `User-Agent: Marracat/<build> …` plus header `X-Marracat-Device: <stable install id>`, 16–128 characters of `[A-Za-z0-9_-]`. The build is read from the User-Agent.
- **Platform:** set by the sender: `ios` for the app, `web` otherwise. An event may override it with `platform: "ios" | "web"`.
- **Signed in:** decided by the server from the session (the website's cookie, the app's Bearer token), never by the body. A signed-in account is stored only as an HMAC of its id under a server secret (`user_hash`).
- **What is never stored:**
  - IP addresses;
  - raw visitor, device or account ids;
  - emails, names, addresses;
  - free text other than a search query. A query is lower-cased and capped at 80 characters, and one that looks like an email or holds 6+ digits is refused.
- **Validation:**
  - Every prop is checked against its schema below, and props not listed are dropped.
  - An event missing a required prop is refused.
  - In a batch, invalid events are dropped. If none are valid, the reply is 400.
- **Limits:**
  - 180 requests a minute per address;
  - 900 events a minute per address, however they are batched;
  - 24 kB per request;
  - rows are kept 180 days.
- **Left out:**
  - crawlers;
  - the owner's own browsing (by account);
  - the owner's phone (by account, or by an address the owner's signed-in phone used today).

## Value types

| Type | Rule |
|---|---|
| product | catalog product id, `[\w.-]{1,160}` |
| brand | catalog brand id, `[a-z0-9][a-z0-9-]{0,79}`, lower-cased |
| row | `[a-z][a-z0-9_:-]{0,40}` |
| duration bucket | seconds, bucketed: `0-10`, `10-30`, `30-60`, `60-180`, `180-600`, `600-1800`, `1800-3600`, `3600+` |
| dwell bucket | seconds: `0-3`, `3-10`, `10-30`, `30-60`, `60-180`, `180+` |
| subtotal bucket | in the order's currency: `0-25`, `25-50`, `50-100`, `100-250`, `250-500`, `500+` |

## Events

Props marked * are required.

### Finding things

| Event | Props | Fired by |
|---|---|---|
| `search` | q* (search text, see above), n (results, int), source (`typed`, `suggestion`, `recent`) | App and website, once per submitted search |
| `product_open` | product*, brand | Website: a product page opened (kept from the first version; it counts as a product view in reports) |
| `product_view` | product*, brand, source (row: where it was opened from, e.g. `search`, `home`, `brand`, `pairs`), dwell_s (dwell bucket) | App: when a product page closes, with its dwell |
| `screen_view` | screen* (`home`, `search`, `browse`, `aisle`, `brand`, `product`, `cart`, `checkout_review`, `orders`, `order_detail`, `account`, `saved`, `lists`, `alerts`, `social`, `boosts`), brand, product | App: each screen change. Website: each page change; pages map to screens in `screenFor` (src/events.js): `/` home, `/shop` search / brand (brand only) / aisle / browse, quality-label pages and `/brands` browse, `/product`, `/cart`, `/checkout` checkout_review, `/account`, `/saved`, `/boosts`. Other pages send none |
| `filter_apply` | filter* (`in_stock`, `sale`, `under_25`, `clean`, `metal`, `scent`, `safer`, `food`, `baby`, `fiber`, `fabric`, `lab`, `pet`, `material`, `home`, `sort`, `brand`, `type`, `aisle`, `category`), value* (see below) | App and website, when a filter changes |

`filter_apply` values:
- **Switches:** `on` or `off`.
- **sort:** `featured`, `low`, `high` or `new`.
- **type:** `department:aisle`.
- **brand, aisle and category:** a catalog id.

### Recommendation rows

| Event | Props | Fired by |
|---|---|---|
| `rec_view` | row*, product, brand, position (0–999) | App and website (website: the product page's "Goes well with" row, `complements`, once per product, `product` = the page's product): a recommendation row came on screen. Rows: `search`, `taste`, `restock`, `pairs`, `complements`, `dept_mix`, `discover`, … |
| `rec_tap` | row*, product, brand, position | A product in that row was tapped |

### Banners

| Event | Props | Fired by |
|---|---|---|
| `banner_view` | kind* (`featured_banner`), brand* | App: the search screen's Featured banner showed a premier brand's page, once per brand each time search is opened |
| `banner_tap` | kind*, brand* | App: that banner tapped (opens the brand's store) |

### Keeping things

| Event | Props | Fired by |
|---|---|---|
| `save` / `unsave` | product*, brand | App and website: Save / heart on a product |
| `brand_follow` / `brand_unfollow` | brand* | App: following a brand. Website: a brand's "Sale alerts" button (sent together with `alert_on`/`alert_off` kind `brand_sale`) |
| `alert_on` / `alert_off` | kind* (`restock`, `price`, `brand_sale`, `brand_drops`, `interest`), product, brand | App: restock, price-drop, brand-sale, new-drop (`brand_drops`, a brand watched for new products) or interest alerts. Website: "Track price" (`price`, product) and "Sale alerts" (`brand_sale`, brand), after the server accepts the change |
| `list_create` | none | A saved-items folder/list made |
| `list_add` | product*, brand | A product put in a list |

### Buying

| Event | Props | Fired by |
|---|---|---|
| `add_to_cart` / `remove_from_cart` | product*, brand, qty (1–99) | App and website: cart changes (website: Add to cart; Remove on the cart page) |
| `buy_click` | brand*, via* (`cart`, `bigcartel`, `swell`, `checkout`, `brand_site`), product | Website: a Buy link leaving for a brand's checkout |
| `checkout_start` | via* (the buy_click values plus `buy_now`, `review`, `ucp`), brand, item_count (1–99), subtotal (subtotal bucket) | App: Buy Now or a brand's checkout opened. Website: "Check out" / "Review all checkouts" (via `review`, brand when one, subtotal when one currency), and every Buy link that leaves for a checkout (the same via as its `buy_click`; not `brand_site`) |
| `checkout_complete` | same as checkout_start, plus step, shipping (dollars, bucketed 0-1 = free … 25+) | App: the brand's checkout reported an order. Website: "Paid — remove from cart" on the review page (via `checkout`; the shopper's word, not the store's) |
| `checkout_abandon` | same as checkout_start, plus step (opened · started · contact · address · shipping · payment: the furthest of Checkout Kit's standard pixel events), shipping | App: a checkout sheet closed without an order; step says how far it got (owner, 2026-11-08) |

### Social and sharing

| Event | Props | Fired by |
|---|---|---|
| `share` | kind* (`product`, `brand`, `list`, `app`, `profile`, `aisle`), target (an id) | App and website share buttons (website: a product's Share, a brand page's Share) |
| `comment_post` | product*, brand | App and website: a comment posted on a product (that one was, never its text) |

### App life cycle and notifications

| Event | Props | Fired by |
|---|---|---|
| `app_open` | cold (bool) | App: launch or return to the foreground |
| `session_end` | duration_s* (duration bucket) | App: going to the background |
| `notification_open` | kind* (row-shaped, e.g. `shipped`, `out_for_delivery`, `delivered`, `restock`, `price_drop`, `sale`, `interest`, `social`) | App: a push notification tapped |

### Accounts (the provider only)

| Event | Props | Fired by |
|---|---|---|
| `sign_in_start` | provider* (`apple`, `google`, `email`, `passkey`) | App and website: a sign-in button tapped |
| `sign_in_complete` | provider* | App: signed in. Website: back from the provider with a session (the provider is remembered in sessionStorage across the redirect) |
| `sign_in_cancel` | provider*, step (challenge · provider · exchange) | App: the shopper closed the Apple or Google sheet (owner, 2026-11-08: where sign-ins stop) |
| `sign_in_fail` | provider*, step, reason (cancelled · error · network · server) | App: the provider or our token exchange failed |
| `sign_up_complete` | provider* | App: a new account made (the website can't tell a new account from a returning one, so it doesn't send this) |

### Looking closer

| Event | Props | Fired by |
|---|---|---|
| `label_sheet_open` | label* (row-shaped label id, e.g. `clean`, `true_metal`, `natural_fiber`), product | A quality label's explanation opened |
| `gallery_open` | product* | The photo gallery opened |
| `brand_instagram` | brand* | The brand page's Instagram button (app; only brands whose site links an account) |
| `gallery_zoom` | product* | A photo zoomed (pinch or double-tap), once per photo per visit |

## Website speed (not an event)

The website also sends one small report per page load to `POST /api/vitals` as the page is left (`src/vitals.js`,
`server/vitals.js`). It is kept in its own table, `web_vitals`, so a page load never counts as a visitor doing
something. A row holds no visitor id, address or user agent: only the day, the kind of page, and each timing as a
range: server answer (`ttfb`), first paint (`fcp`), main content shown (`lcp`), slowest tap (`inp`), layout shift
(`cls`), seconds until the catalog could be searched (`catalog`) and where it came from (`device`, `network`, `page`),
the connection type the browser reports, and whether it was a repeat visit or the installed web app. Kept 90 days.

## Reading it

`DATA_DIR=/var/lib/marracat node server/events-report.js --days 7 [--json]` on the server prints:

- the funnel by platform: opened, then product view, add to cart, checkout start, checkout complete;
- top searches;
- Buy clicks by brand and route;
- top screens;
- saves, follows, alerts and lists;
- the sign-in funnel by provider;
- notification opens;
- recommendation rows (views, taps, tap rate; 7 and 30 days);
- people: DAU (today and average), WAU, came back on 2+ days, returning from before the window, signed-in vs guests, accounts;
- the website's visit-count returning visitors;
- website speed for real visits: the share of loads that were good and poor for each timing.
