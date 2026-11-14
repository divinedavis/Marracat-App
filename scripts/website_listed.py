#!/usr/bin/env python3
"""What marracat.com will serve from a catalog: the products it lists.

The website leaves out a product whose title is nothing but the ownership
wording it omits (web/server/website-copy.js, websiteLabel + websiteListed;
the book "Independent", 2026-11-11). The deploy checks compare the live
/api/catalog count against this, not against every product in the file:
counting all of them failed the droplet's 2026-11-11 23:00Z publish
(194,307 served vs 194,308 expected) and rolled marracat.com back.

    scripts/website_listed.py <catalog.json>    -> "<generated_at> <count> <first listed id>"
    scripts/website_listed.py --labels          -> JSON titles on stdin, website labels out
                                                   (web/tests/website-copy.test.js checks
                                                   these match the JavaScript)
"""
from __future__ import annotations

import json
import re
import sys

WORDING = re.compile(r"\bblack[\s\-‐-―]*owned\b", re.IGNORECASE)
SPACES = re.compile(r"\s{2,}")
EDGES = re.compile(r"^\s*[:—–-]\s*|\s*[:—–-]\s*$")


def website_label(value):
    """websiteLabel: the wording out, spaces and stray edge punctuation tidied."""
    if not isinstance(value, str):
        return value
    return EDGES.sub("", SPACES.sub(" ", WORDING.sub("", value))).strip()


def listed(product: dict) -> bool:
    """websiteListed, applied to the website's copy of the product."""
    title = website_label(product.get("title"))
    return isinstance(title, str) and len(title.strip()) > 0


def expectations(path: str) -> tuple[str, int, str]:
    with open(path) as f:
        catalog = json.load(f)
    shown = [p for p in catalog["products"] if listed(p)]
    return catalog["generated_at"], len(shown), shown[0]["id"]


if __name__ == "__main__":
    if sys.argv[1:] == ["--labels"]:
        print(json.dumps([website_label(t) for t in json.load(sys.stdin)], ensure_ascii=False))
    elif len(sys.argv) == 2:
        print(*expectations(sys.argv[1]))
    else:
        sys.exit(__doc__)
