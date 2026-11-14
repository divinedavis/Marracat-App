#!/usr/bin/env python3
"""Find each brand's Instagram from its own website, for the Instagram
button on the brand page (owner, 2026-10-17: "you can probably find the
instagram of each brand from their website - if they dont have their
instagram on their website dont put a button on their page").

    python3 catalog/instagram_handles.py            # brands not yet scanned
    python3 catalog/instagram_handles.py --all      # rescan every brand

Reads the home page (where the footer's social links live) and keeps the
account it links to most. Nothing else is guessed: no link, no handle, no
button. Post, reel and share links aren't accounts. Writes `instagram`
into catalog/brands.json, and `instagram_checked` (the date) so a brand
without one isn't fetched again on every run.
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_catalog import STOREFRONT_TLS, UA  # noqa: E402

BRANDS = Path(__file__).resolve().parent / "brands.json"
# A link to the account itself: one path segment, then the end of the URL.
# Media and script paths (instagram.com/v/t51…, /o1/…) have more. Also
# JSON-escaped ("instagram.com\/brand"), as themes store settings.
LINK = re.compile(r"instagram\.com\\?/(?:#!\\?/)?([A-Za-z0-9._]{2,30})(?:\\?/)?(?=[?\"'#\s<&]|\\[\"']|$)", re.I)
# Paths on instagram.com that aren't anyone's account.
NOT_ACCOUNTS = {"p", "reel", "reels", "tv", "stories", "explore", "accounts", "about", "developer", "legal",
                "direct", "web", "share", "sharer", "embed", "embed.js", "static", "images", "instagram",
                "shopify", "privacy", "help", "challenge",
                # Site builders whose templates link their own account.
                "wix", "squarespace", "bigcartel", "godaddy", "weebly", "woocommerce", "swell"}


def handles_in(page: str) -> list[str]:
    """Accounts the page links to, most-linked first."""
    found = Counter()
    for h in LINK.findall(page):
        h = h.rstrip(".").lower()
        # One letter is a script path ("instagram.com/v/…"), not a brand.
        if len(h) > 1 and h not in NOT_ACCOUNTS and not h.startswith("_") and not h.isdigit():
            found[h] += 1
    return [h for h, _ in found.most_common()]


def fetch(domain: str) -> str | None:
    try:
        req = urllib.request.Request(f"https://{domain}/", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=25, context=STOREFRONT_TLS) as r:
            return r.read(3_000_000).decode("utf-8", "replace")
    except Exception as e:
        print(f"  ! {domain}: {e}", file=sys.stderr)
        return None


def main() -> None:
    rescan = "--all" in sys.argv
    brands = json.loads(BRANDS.read_text())
    todo = [b for b in brands if rescan or "instagram_checked" not in b]
    print(f"scanning {len(todo)} of {len(brands)} brands")
    with ThreadPoolExecutor(max_workers=12) as pool:
        pages = list(pool.map(lambda b: fetch(b["domain"]), todo))
    today = date.today().isoformat()
    found = 0
    for b, page in zip(todo, pages):
        if page is None:
            continue   # unreachable today: try again next run
        hs = handles_in(page)
        if hs:
            b["instagram"] = hs[0]
            found += 1
        else:
            b.pop("instagram", None)
        b["instagram_checked"] = today
    BRANDS.write_text(json.dumps(brands, indent=1, ensure_ascii=False) + "\n")
    print(f"{found} of {len(todo)} have an Instagram on their site")


if __name__ == "__main__":
    main()
