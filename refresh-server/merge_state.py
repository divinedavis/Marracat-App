#!/usr/bin/env python3
"""Carry the refresh droplet's generated state across a code update.

The refresh writes tracked files as it runs (Jev verdict caches such as
catalog/jev_brand_fit.json, catalog/ingredients.json, catalog/photo_hashes.json,
the *_report.md files). The droplet never commits; refresh-server/update_checkout.sh
saves those files, resets the checkout to origin/main, then calls this for
each one:

    merge_state.py <saved local copy> <file in the checkout (upstream)>

  - both JSON objects: upstream's entries plus the droplet's, the droplet's
    winning a clash (its verdicts are the newer ones). Top-level only.
  - anything else: the droplet's copy, unless upstream changed the file in
    this update (--upstream-changed), in which case upstream's stays (a
    hand edit beats a regenerated report).
"""
from __future__ import annotations

import json
import pathlib
import sys


def merge(local_text: str, upstream_text: str, upstream_changed: bool) -> str:
    try:
        local, upstream = json.loads(local_text), json.loads(upstream_text)
    except ValueError:
        return upstream_text if upstream_changed else local_text
    if isinstance(local, dict) and isinstance(upstream, dict):
        if not upstream_changed:
            return local_text
        merged = {**upstream, **local}
        if list(upstream) == sorted(upstream):
            merged = dict(sorted(merged.items()))
        indent = 0 if "\n" in upstream_text.strip() else None
        sep = None if indent is not None else (",", ":")
        return json.dumps(merged, indent=indent, separators=sep, ensure_ascii=False) + ("\n" if upstream_text.endswith("\n") else "")
    return upstream_text if upstream_changed else local_text


def main(argv: list[str]) -> int:
    changed = "--upstream-changed" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if len(paths) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    local, target = map(pathlib.Path, paths)
    upstream_text = target.read_text() if target.exists() else ""
    out = merge(local.read_text(), upstream_text, changed) if upstream_text else local.read_text()
    target.write_text(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
