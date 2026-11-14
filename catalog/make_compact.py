#!/usr/bin/env python3
"""Write the catalog the app bundles, from the full one the scripts keep.

    python3 catalog/make_compact.py

The app ships every product a brand has in stock, minus the description and
the images after the first — the two fields only a product page reads, and
60% of a product's bytes. The page fetches them from /api/products/:id.

build_catalog.py writes this file too, but ship.sh regenerates it: the catalog
is edited after a build (dedupe, the clean badge), and the bundle must match
what actually ships rather than what the last rebuild produced.

It then writes the same catalog in the app's binary form (catalog.bin) and
Home's first-screen slice of it (catalog-home.bin), with the app's own Swift
code (scripts/catalog_binary/main.swift), so no launch parses the JSON — not
even the first one after an update (2026-10-11). The JSON stays in the bundle
as the fallback.

    python3 catalog/make_compact.py --no-binary   # JSON only (the refresh
                                                  # droplet: no Xcode there)
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from publish_snapshots import compact_catalog  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FULL = ROOT / "Marracat" / "Resources" / "catalog.json"
COMPACT = ROOT / "Marracat" / "Resources" / "catalog-compact.json"
# The app's own catalog code, compiled into the tool that writes the binary.
BINARY_SOURCES = [ROOT / "Marracat" / "Models.swift", ROOT / "Marracat" / "AttributeFilters.swift",
                  ROOT / "Marracat" / "Stores" / "CatalogBinary.swift",
                  ROOT / "Marracat" / "Stores" / "HomeSlice.swift", ROOT / "scripts" / "catalog_binary" / "main.swift"]
BINARY_TOOL = ROOT / "build" / "catalog-binary"


def camel_keys(o):
    """Keys in the app's own spelling (compare_at -> compareAt). Decoding with
    .convertFromSnakeCase re-spells every key of 100k products and was half of
    the launch read (1.0-1.4 s vs 0.6 s on the simulator); the app reads this
    file with plain keys. Older builds decode it too: snake-case conversion
    leaves keys without underscores alone."""
    if isinstance(o, dict):
        return {re.sub(r"_([a-z0-9])", lambda m: m.group(1).upper(), k): camel_keys(v) for k, v in o.items()}
    if isinstance(o, list):
        return [camel_keys(x) for x in o]
    return o


def write_binary(compact: Path = COMPACT, out_dir: Path | None = None) -> None:
    """catalog.bin and catalog-home.bin beside the JSON. The tool is rebuilt
    when any of its sources is newer than it (about 5 s); it reads both files
    back against the JSON and exits non-zero if they don't match."""
    newest = max(p.stat().st_mtime for p in BINARY_SOURCES)
    if not BINARY_TOOL.exists() or BINARY_TOOL.stat().st_mtime < newest:
        BINARY_TOOL.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-O", *map(str, BINARY_SOURCES), "-o", str(BINARY_TOOL)], check=True)
    subprocess.run([str(BINARY_TOOL), str(compact), str(out_dir or compact.parent)], check=True)


def main(argv: list[str] | None = None) -> None:
    argv = sys.argv[1:] if argv is None else argv
    catalog = json.loads(FULL.read_text())
    compact = camel_keys(compact_catalog(catalog))
    write_catalog(COMPACT, compact)
    print(f"bundle: {len(compact['products'])} products, "
          f"{COMPACT.stat().st_size / 1e6:.0f} MB (full catalog is {FULL.stat().st_size / 1e6:.0f} MB)", flush=True)
    if "--no-binary" not in argv:
        write_binary()


if __name__ == "__main__":
    main()
