#!/usr/bin/env python3
"""Publish Marracat's App Privacy labels (ASC app 6810905687).

The public App Store Connect API has no App Privacy resource (every
appDataUsages path 404s under an API key; see app-store/app-privacy-answers.md),
so this drives the private iris API the dashboard itself uses, with the cookie
jar fastlane's Spaceship writes after `fastlane spaceauth -u
divinejdavis@gmail.com`. That needs a person (2FA) and the cookie lasts only
days, so run this within minutes of it. Adapted from Find A Crib's
ios/scripts/asc_push_privacy_iris.py.

Everything is Linked to the user and Not used for tracking (a second purpose
otherwise defaults to not-linked and adds a "Data Not Linked to You" section).
Payment Info is deliberately not declared: card data is entered in the brand's
Shopify checkout and Marracat never has access to it.

Records not in USAGES are deleted, missing ones added, then the publish PATCH. The publish state can only be UPDATEd, never read, so a 200
there is the proof.

    ~/.venvs/marracat/bin/python scripts/asc_push_privacy_iris.py [--probe-only]
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import requests

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from asc import load_config  # noqa: E402

IRIS = "https://appstoreconnect.apple.com/iris/v1"
COOKIE_FILE = pathlib.Path.home() / ".fastlane" / "spaceship" / "divinejdavis@gmail.com" / "cookie"

PROTECTION = "DATA_LINKED_TO_YOU"
# (leaf data type, purpose) — see the docstring and app-store/app-privacy-answers.md.
USAGES = [
    ("NAME", "APP_FUNCTIONALITY"),
    ("EMAIL_ADDRESS", "APP_FUNCTIONALITY"),
    ("PHONE_NUMBER", "APP_FUNCTIONALITY"),
    ("PHYSICAL_ADDRESS", "APP_FUNCTIONALITY"),
    ("USER_ID", "APP_FUNCTIONALITY"),
    ("PURCHASE_HISTORY", "APP_FUNCTIONALITY"),
    ("SEARCH_HISTORY", "APP_FUNCTIONALITY"),
    ("SEARCH_HISTORY", "PRODUCT_PERSONALIZATION"),
    ("PRODUCT_INTERACTION", "APP_FUNCTIONALITY"),
    ("PRODUCT_INTERACTION", "PRODUCT_PERSONALIZATION"),
    # Social features shipped 2026-09-19 (web/server/social.js): public
    # product comments, display name + @handle, report reasons and the
    # decrypted share a reporter chooses to send. Shares themselves are
    # end-to-end encrypted and unreadable by the server, so not "collected".
    ("OTHER_USER_CONTENT", "APP_FUNCTIONALITY"),
    # App launches counted from nginx logs (IP + "Marracat/<build> channel/..."
    # user agent) by web/metrics/marracat_metrics.py for the owner dashboard.
    ("OTHER_USAGE_DATA", "ANALYTICS"),
    # First-party event stream (web/server/events.js, EVENTS.md, 2026-10-11):
    # searches, product views, saves/cart/checkout steps, tied to a hashed
    # device id and (signed in) a keyed hash of the account, for the weekly
    # report. Publish with the app build that starts sending them.
    ("SEARCH_HISTORY", "ANALYTICS"),
    ("PRODUCT_INTERACTION", "ANALYTICS"),
    ("PURCHASE_HISTORY", "ANALYTICS"),
]


def cookies() -> list[dict]:
    """Spaceship's jar is Ruby YAML (!ruby/object:HTTP::Cookie); line-scan it."""
    if not COOKIE_FILE.exists():
        raise SystemExit(f"no cookie at {COOKIE_FILE} — run: fastlane spaceauth -u divinejdavis@gmail.com")
    out: list[dict] = []
    cur: dict | None = None
    for line in COOKIE_FILE.read_text().splitlines():
        if line.lstrip().startswith("- !ruby/object:"):
            if cur and cur.get("name") and cur.get("value"):
                out.append(cur)
            cur = {}
            continue
        if cur is None or ":" not in line:
            continue
        k, _, v = line.strip().partition(":")
        if k.strip() in ("name", "value", "domain") and v.strip():
            cur[k.strip()] = v.strip().strip('"').strip("'")
    if cur and cur.get("name") and cur.get("value"):
        out.append(cur)
    if not out:
        raise SystemExit("parsed 0 cookies from the Spaceship jar")
    return out


def session() -> requests.Session:
    s = requests.Session()
    for c in cookies():
        s.cookies.set(c["name"], c["value"], domain=c.get("domain", "appstoreconnect.apple.com"))
    s.headers.update({
        "Accept": "application/vnd.api+json", "Content-Type": "application/vnd.api+json",
        "X-Requested-With": "XMLHttpRequest",
        "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                       "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"),
        "Origin": "https://appstoreconnect.apple.com", "Referer": "https://appstoreconnect.apple.com/",
    })
    return s


def show(label: str, r: requests.Response) -> None:
    print(f"── {label}  HTTP {r.status_code}")
    try:
        print(json.dumps(r.json(), indent=1)[:1500])
    except Exception:
        print(r.text[:600])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe-only", action="store_true")
    args = ap.parse_args()
    app_id = load_config()["ASC_APP_ID"]
    s = session()

    # The appDataUsages collection refuses GET (403 "does not allow
    # GET_COLLECTION"); the app's relationship path lists them.
    r = s.get(f"{IRIS}/apps/{app_id}/dataUsages", params={"limit": 50}, timeout=30)
    if r.status_code == 401:
        raise SystemExit("iris says 401: the Spaceship cookie has expired — "
                         "run `fastlane spaceauth -u divinejdavis@gmail.com` and retry")
    show("existing appDataUsages", r)
    existing = r.json().get("data", []) if r.ok else []
    if args.probe_only:
        show("categories", s.get(f"{IRIS}/appDataUsageCategories", params={"limit": 200}, timeout=30))
        show("purposes", s.get(f"{IRIS}/appDataUsagePurposes", timeout=30))
        show("dataProtections", s.get(f"{IRIS}/appDataUsageDataProtections", timeout=30))
        return 0

    # Diff rather than wipe: the live listing never shows an empty label while
    # this runs, and a re-run with nothing changed only re-publishes.
    r = s.get(f"{IRIS}/apps/{app_id}/dataUsages",
              params={"limit": 50, "include": "category,purpose,dataProtection"}, timeout=30)
    have = {}
    for e in r.json().get("data", []):
        rel = e.get("relationships", {})
        key = tuple((rel.get(k, {}).get("data") or {}).get("id") for k in ("category", "purpose", "dataProtection"))
        have[key] = e["id"]
    want = {(c, p, PROTECTION) for c, p in USAGES}
    for key, rid in have.items():
        if key not in want:
            d = s.delete(f"{IRIS}/appDataUsages/{rid}", timeout=30)
            if d.status_code >= 400:
                show(f"DELETE {key} failed", d)
                return 1
            print(f"   - removed {key}")

    for category, purpose in USAGES:
        if (category, purpose, PROTECTION) in have:
            continue
        body = {"data": {"type": "appDataUsages", "relationships": {
            "app": {"data": {"type": "apps", "id": app_id}},
            "category": {"data": {"type": "appDataUsageCategories", "id": category}},
            "purpose": {"data": {"type": "appDataUsagePurposes", "id": purpose}},
            "dataProtection": {"data": {"type": "appDataUsageDataProtections", "id": PROTECTION}}}}}
        r = s.post(f"{IRIS}/appDataUsages", data=json.dumps(body), timeout=30)
        if r.status_code >= 400:
            show(f"POST {category}/{purpose} failed (try --probe-only for the valid ids)", r)
            return 1
        print(f"   + {category} / {PROTECTION} / {purpose}")

    r = s.patch(f"{IRIS}/appDataUsagesPublishState/{app_id}", data=json.dumps({"data": {
        "type": "appDataUsagesPublishState", "id": app_id, "attributes": {"published": True}}}), timeout=30)
    if r.status_code >= 400:
        show("publish failed", r)
        return 1
    print("App Privacy published: " + ", ".join(c for c, _ in USAGES) + " (linked, no tracking)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
