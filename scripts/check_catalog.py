#!/usr/bin/env python3
"""Refuse to ship a catalog that is broken or has lost a chunk of its products.

    python3 scripts/check_catalog.py LOCAL.json LIVE_URL [LOCAL.json LIVE_URL ...]

For each pair: LOCAL parses as JSON, carries generated_at, and has brands and
products (every product with an id and a brand); and its product count is not
more than 10% below what LIVE_URL serves right now. The live copy is fetched
here with curl, never parsed on the droplet: that box has 2 GB and loading the
full catalog there takes 1.7 GB. A deliberate shrink (dropping brands on
purpose) passes with ALLOW_SHRINK=1. A LIVE_URL that 404s counts as nothing
live yet.

Called by scripts/publish_catalog.sh (catalog*.json vs marracat.com/catalog*.json)
and web/deploy.sh (the bundled catalog vs marracat.com/api/catalog).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

MAX_DROP = 0.10


def problems(catalog) -> list[str]:
    """What makes this catalog unshippable, or [] if nothing does."""
    if not isinstance(catalog, dict):
        return ["not a JSON object"]
    out = []
    if not catalog.get("generated_at"):
        out.append("no generated_at")
    brands, products = catalog.get("brands"), catalog.get("products")
    if not isinstance(brands, list) or not brands:
        out.append("no brands")
    if not isinstance(products, list) or not products:
        out.append("no products")
    else:
        bad = sum(1 for p in products if not isinstance(p, dict) or not p.get("id") or not p.get("brand"))
        if bad:
            out.append(f"{bad} products without an id or brand")
    return out


def shrink_problem(new: int, live: int | None, allow: bool) -> str | None:
    """A message if `new` products is too far below `live`, else None."""
    if not live:
        return None
    drop = (live - new) / live
    if drop > MAX_DROP and not allow:
        return f"lost {drop:.0%} of its products ({live:,} live -> {new:,}); ALLOW_SHRINK=1 if that is intended"
    return None


def live_products(url: str) -> int | None:
    with tempfile.NamedTemporaryFile(suffix=".json") as tmp:
        r = subprocess.run(["curl", "-sS", "--compressed", "-o", tmp.name, "-w", "%{http_code}",
                            "--max-time", "300", url], capture_output=True, text=True)
        code = r.stdout.strip()
        if code == "404":
            return None
        if r.returncode != 0 or code != "200":
            raise SystemExit(f"!! could not fetch {url}: HTTP {code} {r.stderr.strip()}")
        with open(tmp.name, "rb") as fh:
            return len(json.load(fh).get("products") or [])


def check(local: str, url: str) -> bool:
    try:
        with open(local, "rb") as fh:
            catalog = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"!! {local}: {e}")
        return False
    errs = problems(catalog)
    if errs:
        print(f"!! {local}: " + "; ".join(errs))
        return False
    n = len(catalog["products"])
    live = live_products(url)
    msg = shrink_problem(n, live, os.environ.get("ALLOW_SHRINK") == "1")
    print(f"   {os.path.basename(local)}: {n:,} products vs {f'{live:,}' if live is not None else 'nothing'} live at {url}")
    if msg:
        print(f"!! {local} {msg}")
        return False
    return True


def main(args: list[str]) -> int:
    if not args or len(args) % 2:
        print(__doc__)
        return 2
    ok = [check(args[i], args[i + 1]) for i in range(0, len(args), 2)]
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
