#!/usr/bin/env python3
"""Marracat numbers for the owner dashboard at divinedavis.com/dashboard/?site=marracat.

Runs here, on the droplet that serves marracat.com, because the two things it
reads live here: nginx's access log (root/adm only) and the storefront's SQLite.
A systemd timer runs it every five minutes and it writes one JSON file with
every range precomputed; the Node server hands that file to the dashboard's API
behind a shared key. Nothing in the file names a person — counts only.

Sources:

  nginx log   App launches and devices (the iPhone app identifies itself as
              "Marracat/<build>" and checks /catalog-v3.json (v2 before
              2026-09-24) on a cold launch; a background refresh checks it too,
              so checks from one device within LAUNCH_GAP_S count once), and web storefront visitors (a browser that fetched
              /api/catalog ran the storefront's JavaScript; a scraper that takes
              the HTML and leaves never asks for it).
  SQLite      Accounts, and what signed-in shoppers did: saves, searches,
              product views and ORDERS PLACED — the app records an order only
              when Shopify Checkout Kit reports it complete.

Until 2026-09-18 marracat.com wrote into the box-wide access.log, whose
combined format has no $host. Its lines are still recognisable by path and by
the app's user-agent, which is what `_is_marracat` does; from that day the
vhost has its own log with the host in it and this reads both.

The owner is excluded five ways. Testing installs of the app: from build 46 the
app names its channel in the user agent and only "appstore" counts, and every
earlier build was pre-release (see APPSTORE_BUILDS). The owner's browser once
it has signed in, which marks its catalog requests (OWNER_MARK). A website
visit from a network a testing build used that day, which is a laptop on the
phone's hotspot. Any address a device signed in as the owner used that day
(see server/owner-metrics.js), any address that SSH'd into this droplet, and
MARRACAT_OWNER_NETS (the work proxy's egress pool, which also carries the
Mac's simulator and UI-test runs). A browser that never signed in, on a
network the phone didn't use, can still slip through, so the tiles say
"excluding the owner where known".
"""
import datetime
import glob
import gzip
import ipaddress
import json
import os
import re
import shutil
import sqlite3
import tempfile
import zoneinfo

SHARED_LOG = os.environ.get("MARRACAT_SHARED_LOG", "/var/log/nginx/access.log")
SITE_LOG = os.environ.get("MARRACAT_SITE_LOG", "/var/log/nginx/marracat.access.log")
AUTH_LOG = os.environ.get("MARRACAT_AUTH_LOG", "/var/log/auth.log")
DB_PATH = os.environ.get("MARRACAT_DB", "/var/lib/marracat/marracat.sqlite")
OUT = os.environ.get("MARRACAT_METRICS_OUT", "/var/lib/marracat-metrics/metrics.json")
OWNER_EMAILS = {e.strip().lower() for e in
                os.environ.get("MARRACAT_OWNER_EMAILS", "divinejdavis@gmail.com").split(",") if e.strip()}
SITE_LOG_SINCE = "2026-09-18"
# Networks the owner works from that rotate addresses faster than SSH or a
# sign-in can record them — a corporate proxy's egress pool, for one. CIDRs,
# set in /etc/marracat/metrics.env rather than here.
OWNER_NETS = [ipaddress.ip_network(n.strip(), strict=False)
              for n in os.environ.get("MARRACAT_OWNER_NETS", "").split(",") if n.strip()]

RANGES = ("today", "month", "3m", "6m", "all")
# The dashboard's picker draws its windows in the owner's time zone: "Today"
# from local midnight, "This month" from the 1st (dashboard/index.html
# rangeStart). Until 2026-10-01 this used UTC days and a rolling 30-day
# "month", and on the 1st, when the dashboard asks for "month" because it
# equals "Today", the Today tiles showed 30 days of traffic.
LOCAL = zoneinfo.ZoneInfo(os.environ.get("MARRACAT_DASHBOARD_TZ", "America/New_York"))
# Swift's Date counts from 2001-01-01, not 1970.
APPLE_EPOCH = 978307200

# Both formats: the per-site one puts $host first, the shared one has none.
LINE = re.compile(
    r'^(?:(?P<host>[A-Za-z0-9.-]+) )?(?P<ip>[0-9a-fA-F:.]+) \S+ \S+ \[(?P<ts>[^\]]+)\] '
    r'"(?P<method>\S+) (?P<path>\S+) [^"]*" (?P<status>\d{3}) \S+ '
    r'"(?P<ref>[^"]*)" "(?P<ua>[^"]*)"'
)
APP_UA = re.compile(r"^Marracat/(\d+)")
# Paths no other vhost on this box serves.
MARRACAT_PATH = re.compile(r"^/(?:api/(?:catalog|products/|mobile/|commerce/)|catalog(?:-v2)?\.json|auth/|signin$)")
# Same judgement as the other tabs' crease_metrics.BOT, trimmed to what could
# plausibly run a storefront's JavaScript.
BOT = re.compile(
    r"bot|crawl|spider|slurp|bing|yandex|baidu|duckduck|semrush|ahrefs|petal|bytespider|"
    r"facebookexternalhit|preview|monitor|uptime|curl|wget|python|okhttp|headless|lighthouse|"
    r"pingdom|scanner|googleother|google-inspectiontool|dataprovider|go-http-client|node-fetch|axios",
    re.I,
)
# "A rack, not a person": web/metrics/datacenter.json, shared with the server's
# visit and event beacons (web/server/datacenter.js) so the log count and the
# visitor tile refuse the same networks. Started as dhcr-map
# crease_metrics.DATACENTER_PREFIXES (2026-09-18) plus the ranges that rendered
# this storefront without saying they were crawlers.
def _load_datacenter():
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "datacenter.json")) as f:
        entries = [e for g in json.load(f)["groups"] for e in g["prefixes"]]
    return (tuple(e for e in entries if "/" not in e),
            [ipaddress.ip_network(e, strict=False) for e in entries if "/" in e])


DATACENTER, DATACENTER_NETS = _load_datacenter()


def _datacenter(ip):
    if ip.startswith(DATACENTER):
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr in n for n in DATACENTER_NETS)
# A Chrome more than a year old is an automation build, not a shopper.
STALE_CHROME = 135
# Addresses in one /24 (or /64), same browser, same day, that make a bot farm.
FARM_IPS = 5
CHROME = re.compile(r"Chrome/(\d+)")
# Apple owns 17.0.0.0/8 outright. An app launch from it before release is App
# Review (or TestFlight's own review), not a shopper — counted on its own tile.
APPLE = ipaddress.ip_network("17.0.0.0/8")
PRODUCT = re.compile(r"^/api/products/[^/?]+")
# The app names its install channel in the user agent from build 46:
# "Marracat/46 channel/testflight iOS/26.3". Only "appstore" is a shopper;
# TestFlight, App Review (a sandbox install too) and debug builds are testing.
CHANNEL = re.compile(r"\bchannel/(\w+)")
# Builds from before the app named its channel. None of them had reached the
# App Store when the channel went in, so every one of them was testing. If one
# is ever released, list it in /etc/marracat/metrics.env as
# MARRACAT_APPSTORE_BUILDS=38 so its App Store installs count.
APPSTORE_BUILDS = {int(b) for b in os.environ.get("MARRACAT_APPSTORE_BUILDS", "").split(",") if b.strip().isdigit()}
# The storefront adds this once the owner has signed in on that browser.
OWNER_MARK = re.compile(r"[?&]o=1(?:&|$)")


def _now():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)


def _today():
    return datetime.datetime.now(LOCAL).date()


def _cutoff(rng, today):
    """The first local day in the range, or None for all time."""
    if rng == "today":
        return today
    if rng == "month":
        return today.replace(day=1)
    if rng in ("3m", "6m"):
        return today - datetime.timedelta(days=91 if rng == "3m" else 182)
    return None


LAUNCH_GAP_S = 15 * 60
# The first build whose meaning search runs MobileCLIP2-S4 (2026-10-25). Older
# builds still download S0's files from marracat.com/ml, which stop being
# published once almost no device runs one (owner: "put a widget on the
# dashboard for this").
S4_FROM_BUILD = 167


def _epoch(ts):
    try:
        return datetime.datetime.strptime(ts, "%d/%b/%Y:%H:%M:%S %z").timestamp()
    except ValueError:
        return None


def _days(ts):
    """(UTC day, local day) of a log timestamp. Owner sightings are stored by
    UTC day; ranges are cut by the dashboard's local day."""
    try:
        t = datetime.datetime.strptime(ts, "%d/%b/%Y:%H:%M:%S %z")
    except ValueError:
        return None, None
    return t.astimezone(datetime.timezone.utc).date(), t.astimezone(LOCAL).date()


def _local_day(iso_utc):
    """Local day of a UTC timestamp like SQLite's CURRENT_TIMESTAMP."""
    try:
        t = datetime.datetime.fromisoformat((iso_utc or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        t = t.replace(tzinfo=datetime.timezone.utc)
    return t.astimezone(LOCAL).date()


def _lines(base):
    for path in sorted(glob.glob(base + ".*"), reverse=True) + [base]:
        try:
            opener = gzip.open if path.endswith(".gz") else open
            with opener(path, "rt", errors="replace") as f:
                yield from f
        except OSError:
            continue


def _is_marracat(m):
    host = m.group("host")
    if host:
        return host in ("marracat.com", "www.marracat.com")
    return bool(APP_UA.match(m.group("ua")) or MARRACAT_PATH.match(m.group("path")))


def _ssh_ips():
    ips = set()
    for line in _lines(AUTH_LOG):
        if "Accepted publickey" in line or "Accepted password" in line:
            parts = line.split()
            if "from" in parts:
                ips.add(parts[parts.index("from") + 1])
    return ips


_NET_MEMO = {}


def _owner_net(ip):
    if ip not in _NET_MEMO:
        try:
            addr = ipaddress.ip_address(ip)
            _NET_MEMO[ip] = any(addr in n for n in OWNER_NETS)
        except ValueError:
            _NET_MEMO[ip] = False
    return _NET_MEMO[ip]


def _owner_sightings(db):
    try:
        return {(datetime.date.fromisoformat(d), ip) for d, ip in db.execute("SELECT day, ip FROM owner_sightings")}
    except sqlite3.Error:
        return set()


def collect_log(owner_days, owner_ips):
    """One pass over both logs into per-day facts every range is cut from."""
    app, web, products = [], [], []
    # Networks a testing build of the app used, by day. A laptop on the owner's
    # hotspot shares the phone's carrier block, so a website visit from one of
    # these that day is the owner too.
    testing_nets = set()
    last_check = {}
    for base in (SHARED_LOG, SITE_LOG):
        for raw in _lines(base):
            m = LINE.match(raw)
            if not m or not _is_marracat(m):
                continue
            utc_day, day = _days(m.group("ts"))
            if not day:
                continue
            ip, ua, path = m.group("ip"), m.group("ua"), m.group("path").split("?")[0]
            owner = ip in owner_ips or (utc_day, ip) in owner_days or _owner_net(ip) \
                or bool(OWNER_MARK.search(m.group("path")))
            a = APP_UA.match(ua)
            if a:
                # The app's user-agent carries the build and iOS version but no
                # device id, so a device is an address + agent per day.
                # The catalog check is the launch: v3 since 2026-09-24 (counting
                # only v2 left every launch since then at 0), and repeat checks
                # from the same device within LAUNCH_GAP_S are one launch.
                launch = path in ("/catalog-v2.json", "/catalog-v3.json") and m.group("status") in ("200", "304")
                if launch:
                    at = _epoch(m.group("ts"))
                    prev = last_check.get((ip, ua))
                    last_check[(ip, ua)] = at
                    launch = prev is None or at is None or abs(at - prev) > LAUNCH_GAP_S
                try:
                    apple = ipaddress.ip_address(ip) in APPLE
                except ValueError:
                    apple = False
                build = int(a.group(1))
                channel = CHANNEL.search(ua)
                testing = channel.group(1) != "appstore" if channel else build not in APPSTORE_BUILDS
                if testing and not apple:
                    testing_nets.add((utc_day, _net(ip)))
                app.append((day, ip, ua, build, launch, "apple" if apple else (owner or testing)))
                continue
            if m.group("method") != "GET" or not ua.startswith("Mozilla/") or BOT.search(ua) or _datacenter(ip) \
                    or int((CHROME.search(ua) or [0, 999])[1]) < STALE_CHROME:
                continue
            if path == "/api/catalog" and m.group("status") in ("200", "304"):
                web.append((day, utc_day, ip, ua, m.group("ref") or "", owner))
            elif PRODUCT.match(path) and m.group("status") == "200":
                products.append((day, utc_day, ip, owner))
    # A bot farm: one network block showing up as FARM_IPS or more addresses
    # with the same browser on one day. On 2026-10-24 Leaseweb (AS7203,
    # 152.163.232.0/22) opened one brand or product page from each of ~47
    # addresses with an old Linux Chrome and read as 47 of 49 "visitors". A
    # household or office doesn't rotate through five addresses a day.
    addrs = {}
    for _d, u, ip, ua, _r, _o in web:
        addrs.setdefault((u, _net(ip), ua), set()).add(ip)
    farms = {(u, n) for (u, n, _ua), ips in addrs.items() if len(ips) >= FARM_IPS}
    web = [w for w in web if (w[1], _net(w[2])) not in farms]
    products = [p for p in products if (p[1], _net(p[2])) not in farms]
    # Web lines can come before the app line that marks their network, so the
    # hotspot rule applies once both logs have been read.
    web = [(d, ip, ua, ref, owner or (u, _net(ip)) in testing_nets) for d, u, ip, ua, ref, owner in web]
    products = [(d, ip, owner or (u, _net(ip)) in testing_nets) for d, u, ip, owner in products]
    return app, web, products


def _net(ip):
    """The /24 (IPv4) or /64 (IPv6) an address sits in: close enough to be the
    same carrier pool on the same day, too narrow to catch a stranger."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    return str(ipaddress.ip_network(f"{ip}/{24 if addr.version == 4 else 64}", strict=False))


def _in(day, cutoff):
    return cutoff is None or day >= cutoff


def traffic(rng, app, web, products, today):
    cutoff = _cutoff(rng, today)
    devices, launches, owner_devices, builds, spark = set(), 0, set(), {}, {}
    today_devices, today_launches, apple = set(), 0, set()
    for day, ip, ua, build, launch, owner in app:
        if not _in(day, cutoff):
            continue
        if owner == "apple":
            apple.add((ip, ua))
            continue
        if owner:
            owner_devices.add((ip, ua))
            continue
        devices.add((ip, ua))
        builds.setdefault(build, set()).add((ip, ua))
        s = spark.setdefault(day.isoformat(), {"devices": set(), "launches": 0, "web": set()})
        s["devices"].add((ip, ua))
        if launch:
            launches += 1
            s["launches"] += 1
        if day == today:
            today_devices.add((ip, ua))
            today_launches += launch
    visitors, visits, refs, today_visitors = set(), set(), {}, set()
    for day, ip, ua, ref, owner in web:
        if not _in(day, cutoff) or owner:
            continue
        visitors.add((ip, ua))
        visits.add((day, ip, ua))
        spark.setdefault(day.isoformat(), {"devices": set(), "launches": 0, "web": set()})["web"].add((ip, ua))
        if day == today:
            today_visitors.add((ip, ua))
        host = ref.split("/")[2] if "://" in ref else ""
        if host and "marracat.com" not in host:
            refs[host] = refs.get(host, 0) + 1
    pviews = sum(1 for day, _, owner in products if _in(day, cutoff) and not owner)
    pviews_today = sum(1 for day, _, owner in products if day == today and not owner)
    return {
        "app": {
            "devices": len(devices),
            "launches": launches,
            "devices_today": len(today_devices),
            "launches_today": today_launches,
            "owner_devices_excluded": len(owner_devices),
            "apple_review_devices": len(apple),
            "builds": [{"build": b, "devices": len(v)} for b, v in sorted(builds.items(), reverse=True)][:6],
        },
        "web": {
            "visitors": len(visitors),
            "visits": len(visits),
            "product_views": pviews,
            "visitors_today": len(today_visitors),
            "product_views_today": pviews_today,
            "referrers": [{"host": h, "hits": n} for h, n in sorted(refs.items(), key=lambda kv: -kv[1])[:5]],
        },
        "sparkline": [{"date": d, "app_devices": len(v["devices"]), "launches": v["launches"],
                       "web_visitors": len(v["web"])} for d, v in sorted(spark.items())][-14:],
    }


def shoppers(db, rng, today):
    cutoff = _cutoff(rng, today)
    rows = db.execute(
        "SELECT u.id, u.email, u.created_at, p.data, a.user_id IS NOT NULL FROM users u "
        "LEFT JOIN mobile_profiles p ON p.user_id = u.id LEFT JOIN mobile_accounts a ON a.user_id = u.id"
    ).fetchall()
    out = {"accounts": 0, "new": 0, "new_today": 0, "owner_excluded": 0, "app_accounts": 0,
           "providers": {}, "saved": 0, "searches": 0, "viewed": 0,
           "orders": 0, "orders_today": 0, "items": 0, "gmv_usd": 0.0, "brands": 0, "first_order": None,
           "buyers": 0}
    brands = set()
    for uid, email, created, data, app_acct in rows:
        if (email or "").lower() in OWNER_EMAILS:
            out["owner_excluded"] += 1
            continue
        out["accounts"] += 1
        out["app_accounts"] += bool(app_acct)
        provider = uid.split(":", 1)[0] if ":" in uid else "web"
        out["providers"][provider] = out["providers"].get(provider, 0) + 1
        joined = _local_day(created)
        if joined and _in(joined, cutoff):
            out["new"] += 1
        if joined == today:
            out["new_today"] += 1
        try:
            p = json.loads(data) if data else {}
        except ValueError:
            p = {}
        # A profile keeps only its most recent saves, searches and views, so
        # these are "right now" counts, not totals over the range.
        out["saved"] += len(p.get("saved") or [])
        out["searches"] += len(p.get("recentSearches") or [])
        out["viewed"] += len(p.get("recentlyViewed") or [])
        bought = False
        for c in p.get("checkouts") or []:
            try:
                day = datetime.datetime.fromtimestamp(float(c.get("date")) + APPLE_EPOCH, LOCAL).date()
            except (TypeError, ValueError, OverflowError):
                continue
            if not _in(day, cutoff):
                continue
            out["orders"] += 1
            bought = True
            out["orders_today"] += day == today
            out["items"] += int(c.get("itemCount") or 0)
            if (c.get("currency") or "USD") == "USD":
                out["gmv_usd"] += float(c.get("total") if c.get("total") is not None else c.get("subtotal") or 0)
            brands.add(c.get("brandID"))
            iso = day.isoformat()
            out["first_order"] = min(out["first_order"] or iso, iso)
        out["buyers"] += bought
    out["brands"] = len(brands)
    out["gmv_usd"] = round(out["gmv_usd"], 2)
    return out


def late_shipments(db, rng, today):
    """Brands shoppers marked "Late shipment" on an order (server/late-shipments.js),
    most reports first. The owner's own taps are left out when they were signed in."""
    cutoff = _cutoff(rng, today)
    try:
        rows = db.execute("SELECT device, brand_id, brand_name, created FROM late_shipments WHERE owner = 0").fetchall()
    except sqlite3.Error:
        return {"reports": 0, "brands": []}
    brands = {}
    for device, brand_id, name, created in rows:
        day = datetime.datetime.fromtimestamp(created / 1000, LOCAL).date()
        if not _in(day, cutoff):
            continue
        b = brands.setdefault(brand_id, {"brand": brand_id, "name": name, "reports": 0, "shoppers": set()})
        b["reports"] += 1
        b["shoppers"].add(device)
    ranked = sorted(brands.values(), key=lambda b: (-b["reports"], b["name"].lower()))
    return {"reports": sum(b["reports"] for b in ranked),
            "brands": [{**b, "shoppers": len(b["shoppers"])} for b in ranked[:15]]}


UNIT = re.compile(r"^\s*([\d.,]+)\s*([a-zA-Z]*)")
TO_MS = {"ms": 1, "s": 1000, "sec": 1000, "min": 60000}
TO_MB = {"kb": 1 / 1024, "mb": 1, "gb": 1024, "b": 1 / 1048576}


def _amount(text, scale):
    """MetricKit writes measurements as text: "1,000 ms", "212,992 kB"."""
    m = UNIT.match(str(text or ""))
    if not m:
        return None
    factor = scale.get(m.group(2).lower())
    return float(m.group(1).replace(",", "")) * factor if factor else None


def _histogram(h):
    """[(midpoint ms, count)] from a MetricKit histogram."""
    out = []
    for b in ((h or {}).get("histogramValue") or {}).values():
        lo, hi = _amount(b.get("bucketStart"), TO_MS), _amount(b.get("bucketEnd"), TO_MS)
        if lo is not None and hi is not None and b.get("bucketCount"):
            out.append(((lo + hi) / 2, int(b["bucketCount"])))
    return out


def _median(points):
    total = sum(n for _, n in points)
    if not total:
        return None
    seen = 0
    for value, n in sorted(points):
        seen += n
        if seen * 2 >= total:
            return round(value)
    return None


def app_performance(db):
    """MetricKit from real iPhones (server/app-metrics.js), per build, newest
    first: median time to first draw and hang, peak memory, crashes, hangs."""
    try:
        rows = db.execute("SELECT device, kind, build, report FROM app_metrics").fetchall()
    except sqlite3.Error:
        return []
    builds = {}
    for device, kind, build, report in rows:
        b = builds.setdefault(build, {"devices": set(), "reports": 0, "launch": [], "hang": [],
                                      "memory": [], "crashes": 0, "hangs": 0})
        b["devices"].add(device)
        b["reports"] += 1
        try:
            r = json.loads(report)
        except ValueError:
            continue
        if kind == "metric":
            b["launch"] += _histogram((r.get("applicationLaunchMetrics") or {}).get("histogrammedTimeToFirstDraw"))
            b["hang"] += _histogram((r.get("applicationResponsivenessMetrics") or {}).get("histogrammedAppHangTime"))
            peak = _amount((r.get("memoryMetrics") or {}).get("peakMemoryUsage"), TO_MB)
            if peak is not None:
                b["memory"].append(peak)
        else:
            b["crashes"] += len(r.get("crashDiagnostics") or [])
            b["hangs"] += len(r.get("hangDiagnostics") or [])
    out = []
    for build, b in sorted(builds.items(), key=lambda kv: -int(kv[0]) if kv[0].isdigit() else 0)[:8]:
        out.append({"build": build, "devices": len(b["devices"]), "reports": b["reports"],
                    "launch_ms": _median(b["launch"]), "launches": sum(n for _, n in b["launch"]),
                    "hang_ms": _median(b["hang"]),
                    "peak_memory_mb": round(sorted(b["memory"])[len(b["memory"]) // 2]) if b["memory"] else None,
                    "crashes": b["crashes"], "hangs": b["hangs"]})
    return out


def roster(db):
    """One row per shopper account for the owner dashboard's Marracat Users
    page (2026-09-28). Owner accounts stay in, flagged, so the page can say
    which row is the owner's own testing."""
    rows = db.execute(
        "SELECT u.id, u.name, u.email, u.created_at, p.data, a.user_id IS NOT NULL FROM users u "
        "LEFT JOIN mobile_profiles p ON p.user_id = u.id LEFT JOIN mobile_accounts a ON a.user_id = u.id"
    ).fetchall()
    out = []
    for uid, name, email, created, data, app_acct in rows:
        try:
            p = json.loads(data) if data else {}
        except ValueError:
            p = {}
        orders, spend = 0, 0.0
        for c in p.get("checkouts") or []:
            orders += 1
            if (c.get("currency") or "USD") == "USD":
                try:
                    spend += float(c.get("total") if c.get("total") is not None else c.get("subtotal") or 0)
                except (TypeError, ValueError):
                    pass
        out.append({
            "name": name or None, "email": email or None,
            "provider": uid.split(":", 1)[0] if ":" in uid else "web",
            "joined": (created or "")[:10] or None, "app": bool(app_acct),
            "saved": len(p.get("saved") or []), "searches": len(p.get("recentSearches") or []),
            "viewed": len(p.get("recentlyViewed") or []), "orders": orders, "spend_usd": round(spend, 2),
            "owner": (email or "").lower() in OWNER_EMAILS,
        })
    out.sort(key=lambda r: r["joined"] or "", reverse=True)
    return out


# ---- visits table (server/visits.js): the Find A Crib-style tiles ------------

SEARCH_HOSTS = ("google.", "bing.", "duckduckgo.", "yahoo.", "ecosia.", "search.brave.")
SOCIAL_HOSTS = ("tiktok.", "instagram.", "facebook.", "fb.", "t.co", "x.com", "twitter.", "pinterest.",
                "youtube.", "reddit.", "threads.", "snapchat.", "linkedin.")


def _source(platform, ref, src):
    if platform == "ios":
        return "app"
    if src:
        return "tagged"
    if not ref:
        return "direct"
    if any(h in ref for h in SEARCH_HOSTS):
        return "search"
    if any(ref.startswith(h) or ("." + h) in ("." + ref) for h in SOCIAL_HOSTS):
        return "social"
    return "referral"


def visit_rows(db):
    """{visitor: {"days": set, "first": (day, platform, ref, src), "platform": ...}},
    leaving out the owner's visitors and test builds (simulator, TestFlight)."""
    try:
        rows = db.execute("SELECT day, visitor, platform, channel, ref_host, src, first, user_id FROM visits").fetchall()
    except sqlite3.Error:
        return {}
    owner_ids = {r[0] for r in db.execute("SELECT id, email FROM users").fetchall() if (r[1] or "").lower() in OWNER_EMAILS}
    owners = {v for _, v, *_rest, uid in rows if uid in owner_ids}
    # Browsers and phones labelled as the owner's (server/label-visitor.js).
    try:
        owners |= {v for (v,) in db.execute("SELECT visitor FROM visitor_labels WHERE kind='owner'")}
    except sqlite3.Error:
        pass
    out = {}
    for day, v, platform, channel, ref, src, first, uid in rows:
        if v in owners or (platform == "ios" and channel not in (None, "appstore")):
            continue
        d = datetime.date.fromisoformat(day)
        e = out.setdefault(v, {"days": set(), "platform": platform, "first": None})
        e["days"].add(d)
        if first:
            e["first"] = (d, platform, ref or "", src or "")
    for e in out.values():
        if not e["first"]:
            e["first"] = (min(e["days"]), e["platform"], "", "")
    return out


def visits_range(vis, rng, today):
    cutoff = _cutoff(rng, today)
    inr = [e for e in vis.values() if any(_in(d, cutoff) for d in e["days"])]
    returning = sum(1 for e in inr if len(e["days"]) > 1)
    return {"visitors": len(inr), "returning": returning,
            "web": sum(1 for e in inr if e["platform"] == "web"), "app": sum(1 for e in inr if e["platform"] == "ios")}


def engagement(vis, today):
    def actives(start, end):
        return sum(1 for e in vis.values() if any(start <= d <= end for d in e["days"]))
    day = datetime.timedelta(days=1)
    mau, mau_prior = actives(today - 29 * day, today), actives(today - 59 * day, today - 30 * day)
    wau, wau_prior = actives(today - 6 * day, today), actives(today - 13 * day, today - 7 * day)
    dau7 = sum(actives(today - i * day, today - i * day) for i in range(7)) / 7
    app30 = sum(1 for e in vis.values() if e["platform"] == "ios" and any(d >= today - 29 * day for d in e["days"]))
    return {"mau": mau, "mau_prior": mau_prior, "wau": wau, "wau_prior": wau_prior,
            "dau_7d_mean": round(dau7, 2), "stickiness": round(dau7 / mau, 4) if mau else None, "app_actives_30d": app30}


def retention(vis, today):
    out = {}
    for n in (1, 7, 30):
        cohort = [e for e in vis.values() if e["first"][0] <= today - datetime.timedelta(days=n)]
        back = sum(1 for e in cohort if any(e["first"][0] < d <= e["first"][0] + datetime.timedelta(days=n) for d in e["days"]))
        out[f"d{n}"] = {"cohort": len(cohort), "returned": back, "rate": round(back / len(cohort), 4) if cohort else None}
    return out


def sources(vis, today):
    since = today - datetime.timedelta(days=29)
    out = {k: 0 for k in ("direct", "search", "social", "referral", "tagged", "app")}
    for e in vis.values():
        d, platform, ref, src = e["first"]
        if d >= since:
            out[_source(platform, ref, src)] += 1
    out["new"] = sum(out.values())
    out["organic_share"] = round((out["search"] + out["social"] + out["referral"]) / out["new"], 4) if out["new"] else None
    return out


def growth(db, today):
    rows = [r for r in db.execute("SELECT email, created_at FROM users").fetchall() if (r[0] or "").lower() not in OWNER_EMAILS]
    days = [_local_day(c) for _, c in rows]
    day = datetime.timedelta(days=1)
    return {"new_30d": sum(1 for d in days if d and d >= today - 29 * day),
            "new_prior_30d": sum(1 for d in days if d and today - 59 * day <= d <= today - 30 * day),
            "all_time": len(rows)}


def daily_series(vis, db, today, first_day):
    signups = {}
    for email, created in db.execute("SELECT email, created_at FROM users").fetchall():
        d = _local_day(created)
        if d and (email or "").lower() not in OWNER_EMAILS:
            signups[d] = signups.get(d, 0) + 1
    # Per day: everyone, split web / App Store app, and returning (seen on an
    # earlier day) for the dashboard's "Metrics over time" chart (owner,
    # 2026-10-24: "i also need this widget for marracat", Find A Crib's chart).
    per, web, app, back = {}, {}, {}, {}
    for e in vis.values():
        first = min(e["days"])
        side = web if e["platform"] == "web" else app
        for d in e["days"]:
            per[d] = per.get(d, 0) + 1
            side[d] = side.get(d, 0) + 1
            if d > first:
                back[d] = back.get(d, 0) + 1
    start = first_day or today
    days, d = [], start
    while d <= today:
        days.append({"date": d.isoformat(), "visitors": per.get(d, 0), "web": web.get(d, 0), "app": app.get(d, 0),
                     "returning": back.get(d, 0), "signups": signups.get(d, 0)})
        d += datetime.timedelta(days=1)
    return days


# The investor card's own Period, as on Find A Crib (owner, 2026-11-11: "do
# the same style for this one"). Each window carries its tiles' numbers and a
# day-by-day line per tile: the window, and the window before it (None on all
# time). Every line ENDS ON ITS TILE'S NUMBER - window counts run as a total
# from the window's first day (so the line before ends on the "was"),
# weekly actives and daily/monthly are as they stood each day, return rates
# are by first-visit day over the window that ended n days ago.
INVESTOR_WINDOWS = {"14": 14, "30": 30, "60": 60, "90": 90, "all": None}


def _checkout_days(db):
    """{account id: sorted [(local day, USD total)]} for non-owner accounts,
    and the local day each non-owner account was created."""
    rows = db.execute("SELECT u.id, u.email, u.created_at, p.data FROM users u "
                      "LEFT JOIN mobile_profiles p ON p.user_id = u.id").fetchall()
    orders, joined = {}, []
    for uid, email, created, data in rows:
        if (email or "").lower() in OWNER_EMAILS:
            continue
        joined.append(_local_day(created))
        try:
            p = json.loads(data) if data else {}
        except ValueError:
            p = {}
        for c in p.get("checkouts") or []:
            try:
                d = datetime.datetime.fromtimestamp(float(c.get("date")) + APPLE_EPOCH, LOCAL).date()
            except (TypeError, ValueError, OverflowError):
                continue
            usd = float(c.get("total") if c.get("total") is not None else c.get("subtotal") or 0) \
                if (c.get("currency") or "USD") == "USD" else 0.0
            orders.setdefault(uid, []).append((d, usd))
    return {k: sorted(v) for k, v in orders.items()}, joined


def _running(firsts, days):
    """Running count of the dates in `firsts` (None ignored) up to each day."""
    per = {}
    for d in firsts:
        if d is not None:
            per[d] = per.get(d, 0) + 1
    out, total = [], 0
    for d in days:
        total += per.get(d, 0)
        out.append(total)
    return out


def _first_between(dates, lo, hi):
    inside = [d for d in dates if lo <= d <= hi]
    return min(inside) if inside else None


def investor(vis, db, today, first_day):
    day = datetime.timedelta(days=1)
    orders, joined = _checkout_days(db)
    by_day = {}
    for v, e in vis.items():
        for d in e["days"]:
            by_day.setdefault(d, set()).add(v)

    def rolling(d, length):
        seen = set()
        for i in range(length):
            seen |= by_day.get(d - i * day, set())
        return len(seen)

    def dau_mean(d):
        return sum(len(by_day.get(d - i * day, ())) for i in range(7)) / 7

    def ratio(a, b, places=4):
        return round(a / b, places) if b else None

    def window(n, all_time):
        cur = [today - (n - 1 - i) * day for i in range(n)]
        prev = None if all_time else [d - n * day for d in cur]
        spans = [("cur", cur)] + ([("prev", prev)] if prev else [])
        S = {}

        def put(key, fn):
            S[key] = {"cur": fn(cur), "prev": fn(prev) if prev else None}

        put("actives", lambda ds: _running([_first_between(e["days"], ds[0], ds[-1]) for e in vis.values()], ds))
        put("app_actives", lambda ds: _running([_first_between(e["days"], ds[0], ds[-1])
                                                for e in vis.values() if e["platform"] == "ios"], ds))
        put("accounts", lambda ds: _running([d for d in joined if d and ds[0] <= d <= ds[-1]], ds))

        def organic(ds):
            new = _running([e["first"][0] for e in vis.values() if ds[0] <= e["first"][0] <= ds[-1]], ds)
            org = _running([e["first"][0] for e in vis.values() if ds[0] <= e["first"][0] <= ds[-1]
                            and _source(*e["first"][1:]) in ("search", "social", "referral")], ds)
            return [ratio(o, t) for o, t in zip(org, new)]
        put("organic", organic)

        def buyers(ds):
            got = _running([_first_between([d for d, _ in o], ds[0], ds[-1]) for o in orders.values()], ds)
            acc = [sum(1 for d in joined if d and d <= x) for x in ds]
            return [ratio(b, a) for b, a in zip(got, acc)]
        put("buyers", buyers)
        put("wau", lambda ds: [rolling(d, 7) for d in ds])
        put("stickiness", lambda ds: [ratio(dau_mean(d), rolling(d, 30)) for d in ds])

        ret = {}
        for k in (1, 7, 30):
            def rate(ds, k=k):
                arrive = [d - k * day for d in ds]
                coh = [e for e in vis.values() if arrive[0] <= e["first"][0] <= arrive[-1]]
                back = [e["first"][0] for e in coh
                        if any(e["first"][0] < d <= e["first"][0] + k * day for d in e["days"])]
                c, r = _running([e["first"][0] for e in coh], arrive), _running(back, arrive)
                return [ratio(b, t) for b, t in zip(r, c)], (c[-1] if c else 0)
            cr, cohort = rate(cur)
            S["d%d" % k] = {"cur": cr, "prev": rate(prev)[0] if prev else None}
            ret["d%d" % k] = {"rate": cr[-1] if cr else None, "cohort": cohort}

        lo, hi = cur[0], cur[-1]
        src = {k: 0 for k in ("direct", "search", "social", "referral", "tagged", "app")}
        for e in vis.values():
            if lo <= e["first"][0] <= hi:
                src[_source(*e["first"][1:])] += 1
        new = sum(src.values())
        in_win = [[(d, usd) for d, usd in o if lo <= d <= hi] for o in orders.values()]
        last = lambda key, side="cur": (S[key][side] or [None])[-1]
        return {
            "n": n, "all_time": all_time, "start": lo.isoformat(),
            "start_d1": (lo - day).isoformat(), "start_d7": (lo - 7 * day).isoformat(),
            "start_d30": (lo - 30 * day).isoformat(),
            "actives": last("actives"), "actives_prior": last("actives", "prev"),
            "app_actives": last("app_actives"), "app_actives_prior": last("app_actives", "prev"),
            "new_accounts": last("accounts"), "new_accounts_prior": last("accounts", "prev"),
            "accounts_all": sum(1 for d in joined if d is None or d <= today),
            "sources": {**src, "new": new, "organic_share": ratio(src["search"] + src["social"] + src["referral"], new)},
            "buyers": sum(1 for o in in_win if o), "gmv_usd": round(sum(u for o in in_win for _, u in o), 2),
            "retention": ret, "series": S,
        }

    out = {}
    for key, n in INVESTOR_WINDOWS.items():
        all_time = n is None
        if all_time:
            # From the first visit, sign-up or order, whichever came first: the
            # visitor log starts later than the earliest accounts.
            firsts = [d for d in [first_day] + joined + [d for o in orders.values() for d, _ in o] if d]
            n = min((today - min(firsts)).days + 1, 3660) if firsts else 1
        out[key] = window(n, all_time)
    # Fixed-length by definition (as Find A Crib's card): every window shows today's.
    wau, wau_prior = rolling(today, 7), rolling(today - 7 * day, 7)
    mau = rolling(today, 30)
    return {"windows": out, "wau": wau, "wau_prior": wau_prior,
            "dau_7d_mean": round(dau_mean(today), 2), "stickiness": ratio(dau_mean(today), mau)}


def search_models(app, today, days=30):
    """Per day: app devices on an S0 build vs an S4 one (a device is an address
    + user-agent per day, as in traffic()). App Review's devices are left out;
    TestFlight and the owner count, since their phones download S0's files too."""
    since = today - datetime.timedelta(days=days - 1)
    per = {}
    for day, ip, ua, build, _launch, owner in app:
        if day < since or owner == "apple":
            continue
        side = "s4" if build >= S4_FROM_BUILD else "s0"
        per.setdefault(day, {"s0": set(), "s4": set()})[side].add((ip, ua))
    series, d = [], since
    while d <= today:
        x = per.get(d, {"s0": set(), "s4": set()})
        series.append({"date": d.isoformat(), "s0": len(x["s0"]), "s4": len(x["s4"])})
        d += datetime.timedelta(days=1)
    week = [x for x in per.items() if x[0] > today - datetime.timedelta(days=7)]
    s0 = len(set().union(*[v["s0"] for _, v in week])) if week else 0
    s4 = len(set().union(*[v["s4"] for _, v in week])) if week else 0
    return {"s4_from_build": S4_FROM_BUILD, "days": series,
            "last7": {"s0": s0, "s4": s4, "s0_share": round(s0 / (s0 + s4), 4) if s0 + s4 else None}}


def restock(db, rng, today):
    cutoff = _cutoff(rng, today)
    owner_ids = {r[0] for r in db.execute("SELECT id, email FROM users").fetchall() if (r[1] or "").lower() in OWNER_EMAILS}
    try:
        rows = db.execute("SELECT user_id, created, fulfilled FROM restock_watches").fetchall()
    except sqlite3.Error:
        return {"signups": 0, "alerts_sent": 0}
    to_day = lambda ms: datetime.datetime.fromtimestamp(ms / 1000, LOCAL).date() if ms else None
    return {"signups": len({u for u, c, _ in rows if u not in owner_ids and c and _in(to_day(c), cutoff)}),
            "alerts_sent": sum(1 for u, _, f in rows if u not in owner_ids and f and _in(to_day(f), cutoff))}


APPSTORE = os.environ.get("MARRACAT_APPSTORE_JSON", "/var/lib/marracat-metrics/appstore.json")


def appstore():
    """App Store first-time downloads, copied here by scripts/asc_downloads.py
    from the owner's Mac (Apple's analytics reports, one to two days behind)."""
    try:
        with open(APPSTORE) as f:
            a = json.load(f)
    except (OSError, ValueError):
        return None
    days = [{"date": d, "downloads": int(v.get("downloads_first", 0))} for d, v in sorted((a.get("days") or {}).items())]
    return {"through": a.get("as_of"), "last7": int((a.get("d7") or {}).get("downloads_first", 0)),
            "last28": int((a.get("d28") or {}).get("downloads_first", 0)),
            "conv_page_view": (a.get("d28") or {}).get("conv_page_view"), "days": days, "note": a.get("note")}


def build():
    today = _today()
    db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    try:
        app, web, products = collect_log(_owner_sightings(db), _ssh_ips())
        ranges = {}
        for rng in RANGES:
            ranges[rng] = {**traffic(rng, app, web, products, today), "shoppers": shoppers(db, rng, today),
                           "late": late_shipments(db, rng, today)}
        users = roster(db)
        performance = app_performance(db)
        vis = visit_rows(db)
        for rng in RANGES:
            ranges[rng]["visits"] = visits_range(vis, rng, today)
            ranges[rng]["restock"] = restock(db, rng, today)
        first_visit = min((min(e["days"]) for e in vis.values()), default=None)
        fac = {"appstore": appstore(),
               "visits_since": first_visit.isoformat() if first_visit else None,
               "engagement": engagement(vis, today), "retention": retention(vis, today),
               "sources": sources(vis, today), "growth": growth(db, today),
               "daily_series": daily_series(vis, db, today, first_visit),
               "investor": investor(vis, db, today, first_visit)}
    finally:
        db.close()
    first = min([d for d, *_ in app] + [d for d, *_ in web], default=None)
    return {
        "generated_at": _now().isoformat(timespec="seconds") + "Z",
        "log_since": first.isoformat() if first else None,
        "site_log_since": SITE_LOG_SINCE,
        "ranges": ranges,
        "users": users,
        "performance": performance,
        "fac": fac,
        "search_models": search_models(app, today),
    }


def main():
    data = build()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT))
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.chmod(tmp, 0o640)
    try:
        # The Node server (user marracat) serves this file; nobody else reads it.
        shutil.chown(tmp, group=os.environ.get("MARRACAT_METRICS_GROUP", "marracat"))
    except (LookupError, PermissionError):
        pass
    os.replace(tmp, OUT)


if __name__ == "__main__":
    main()
