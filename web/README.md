# Marracat domain

`marracat.com` is registered in the owner's Namecheap account, with domain
privacy enabled. Ownership was verified on September 13, 2026; registration
expires September 13, 2027. Registration and API setup are already complete.

Namecheap BasicDNS remains authoritative:

| Host | Type | Value | TTL |
|---|---|---|---|
| @ | A | 167.71.170.219 | 300 |
| www | CNAME | marracat.com. | 300 |

The DNS update preserved unrelated records and checked for concurrent changes
before replacing the zone. Future changes must do the same: Namecheap's
`setHosts` replaces the full record set. Never replace nameservers or remove
mail records to update the website.

## Hosting

The existing DigitalOcean server has a separate Marracat nginx virtual host:

- Document root: `/var/www/marracat` (only public website files).
- Configuration: `/etc/nginx/sites-available/marracat`, linked in `sites-enabled`.
- `index.html` is the landing page; HTTPS and `www` redirect to the apex domain.
- `/catalog.json` proxies the existing public GitHub catalog over verified TLS.
  `scripts/publish_catalog.sh` continues publishing to GitHub, so older app
  versions and the new domain receive the same catalog.
- Let's Encrypt uses the HTTP webroot challenge. `certbot.timer` renews the
  certificate; its deploy hook reloads nginx. Keep the challenge location in
  the HTTP configuration so renewals work.

`nginx-http.conf` is for initial certificate issuance only. `nginx.conf` is the
production configuration once the certificate exists. Prepare files locally,
copy them to the server, run `nginx -t`, then reload nginx. Preserve the other
applications' virtual hosts. Do not deploy this directory wholesale to the
public document root: the `.conf` files are server configuration.

No Namecheap credentials belong in this repository. The local credential file
is `~/.config/marracat/namecheap.json`, with owner-only read/write permissions.
Local setup status and DNS
backups are under the ignored `build/namecheap-status.json` and
`build/namecheap-dns/` paths. The status file references the private credential
file without copying its contents. Verify that local credential file exists
before requesting account setup again. The certificate renewal dry run passed
on September 13, 2026.

## Storefront

The React storefront shares the iOS catalog. `/api/catalog` returns a cached,
compact projection and `/api/products/:id` loads full product details on demand.
The server starts with the bundled snapshot and refreshes from the existing
public catalog every 15 minutes, retaining the last valid data on failure. All catalog
brands appear in the directory, including brands without an imported feed.
Product search, departments, brand filters, price sorting, real discounts,
variant selection, saved items, and a local cart are supported. Shopify cart
links use the catalog's actual variant IDs. Each brand takes its own payment
and handles shipping and returns; opening checkout does not mark an order paid.
Cart and saved items persist in this browser, including for guests.

```sh
cd web
npm ci
npm run build
# Development only: generate a temporary session secret and start the backend.
AUTH_SECRET=$(openssl rand -hex 32) npm start
# In another terminal: npm run dev
npm test
npm run test:browser
```

The auth service runs as the unprivileged `marracat` system user, on loopback
port 3107. Runtime credentials belong in `/etc/marracat/web.env` (0600), never
in the public document root. Account records live in
`/var/lib/marracat/marracat.sqlite`. OAuth sign-in creates the account on first
use and uses encrypted, HttpOnly session cookies. Provider identities are kept
separate rather than linking accounts solely on matching email addresses.

### Marracat Shopify connection

The Marracat Shopify store is `kercqa-hi.myshopify.com`, with USD currency,
Headless and Collective installed, and the Marracat brand assets configured.
The Headless storefront is named `Marracat Headless`. Its private Storefront
API token is stored in `~/.config/marracat/shopify.env` locally and in
`/etc/marracat/shopify.env` on the server (both 0600). The systemd service reads
the server file; it is never copied to the website or committed.

`GET /api/commerce/status` checks authenticated Shopify access and whether any
products are published to this Headless channel. It returns only `connected`
and `hasPublishedProducts`. Concurrent checks share one upstream request and
cache success for 60 seconds, failure for 10 seconds. Connection readiness does
not imply payment, supplier, or checkout readiness.

As of September 13, 2026, the API connection is verified and no products are
published to Headless. Collective reports 4 of 6 eligibility requirements met;
Shopify Payments setup and a matching USD payout bank account remain pending.
The website still uses each brand's existing checkout links. Unified checkout
requires eligible supplier imports, publication to Headless, catalog/variant
mapping, a Cart API integration, and validation against those actual products.
Never send an original supplier variant ID to Marracat's store: imported
products have their own Shopify IDs.

### Google and Apple activation

No production provider credentials were present during the initial storefront
build. The UI explains availability honestly and guests can continue shopping.
Set credentials securely using the variable names in `.env.example`, then
restart `marracat-web.service`.

- Google: create a Web Application OAuth client in Marracat's Google Cloud
  project. Configure the consent screen for external production use, authorized
  origin `https://marracat.com`, and redirect URI
  `https://marracat.com/auth/callback/google`. Set `AUTH_GOOGLE_ID` and
  `AUTH_GOOGLE_SECRET`.
- Apple: enable Sign in with Apple on the primary Marracat App ID; create a
  Services ID with domain `marracat.com` and return URL
  `https://marracat.com/auth/callback/apple`. Create a Sign in with Apple key
  associated with that App ID. Set `AUTH_APPLE_ID`, `APPLE_TEAM_ID`,
  `APPLE_KEY_ID`, and `APPLE_PRIVATE_KEY_PATH`. Install the key at that path
  outside the web root, readable only by the service. The backend generates a
  fresh client-secret JWT, avoiding a manually rotated six-month secret.
- Verify actual consent, first-time account creation, returning sign-in,
  cancellation, and sign-out with each provider after configuration. Provider
  redirects cannot be fully tested without registered credentials.

References: https://authjs.dev/reference/express and
https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/

### Website releases

`deploy.sh` builds and tests locally, uploads an explicit list of server files
and built public assets, installs locked production dependencies, checks nginx,
and restarts only the Marracat service. It preserves the existing catalog
proxy, TLS renewal challenge, and other sites. The website does not change the
iOS binary, so a TestFlight release is not involved in website-only updates.

## Owner dashboard counts

`metrics/marracat_metrics.py` feeds divinedavis.com/dashboard/?site=marracat.
It counts App Store installs only: from build 46 the app puts its channel in
the user agent (`Marracat/46 channel/testflight iOS/26.3`), and TestFlight,
App Review and debug installs are left out. Builds before 46 carried no
channel and were all pre-release, so they are left out too.

**When a pre-46 build is released on the App Store** (build 38 is the one in
review), add it to `/etc/marracat/metrics.env` as `MARRACAT_APPSTORE_BUILDS=38`,
or its real shoppers will be counted as testing. Builds 46 and later need
nothing.

The owner's browser leaves itself out once it has signed in on the website
(it marks its catalog requests with `o=1`), and a website visit from a network
a testing build used that day is treated as the owner's hotspot.
