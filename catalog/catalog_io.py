"""Writing a catalog file the way every script does: compact separators,
UTF-8 left as is.

Streamed with json.dump rather than built with json.dumps: the full catalog
is ~322 MB of JSON, and json.dumps made all of it one string first, 1.2 GB
on top of the ~3.7 GB the parsed catalog takes (5.2 GB vs 3.7 GB peak per
badge script, measured 2026-10-18; a ship was killed for low memory on the
16 GB Mac). The bytes are identical, about 2.6 s slower per write.

Through a temporary file beside it, so a run killed mid-write leaves the
previous catalog whole.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def write_catalog(path: Path, catalog) -> None:
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(catalog, fh, separators=(",", ":"), ensure_ascii=False)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def products_of_brands(path: Path, wanted, chunk: int = 4 << 20, longest: int = 64 << 20):
    """From a catalog file: the products of the `wanted` brands, by brand, and
    the id of every brand that has any product in it.

    Read one product at a time, never the whole file. build_catalog.py used to
    json.loads the previous catalog to carry a few unreachable stores through:
    3.5 GB of objects beside the catalog it had just built, and on 2026-11-12
    that ran the 4 GB refresh server (plus 4 GB swap) out of memory on two
    runs in a row. This keeps a few megabytes of text and the wanted products.

    A catalog cut short, or with a product that will not parse, gives what was
    read up to there and says so; the caller is only rescuing with it.
    """
    wanted = set(wanted)
    kept: dict[str, list] = {}
    seen: set[str] = set()
    decoder = json.JSONDecoder()
    with Path(path).open(encoding="utf-8") as fh:
        buf, start = "", None
        while start is None:
            more = fh.read(chunk)
            if not more:
                return kept, seen
            buf = buf[-32:] + more          # the key may straddle two reads
            m = re.search(r'"products"\s*:\s*\[', buf)
            start = m.end() if m else None
        pos = start
        while True:
            while pos < len(buf) and buf[pos] in " \t\r\n,":
                pos += 1
            if pos < len(buf) and buf[pos] == "]":
                break
            try:
                if pos >= len(buf):
                    raise ValueError("more to read")
                product, end = decoder.raw_decode(buf, pos)
            except ValueError:
                more = fh.read(chunk)
                # No product is anywhere near `longest` (the biggest today is
                # a quarter of a megabyte): the file is damaged.
                if not more or len(buf) - pos > longest:
                    print(f"  ! {Path(path).name}: stopped reading at a product that does not parse; "
                          f"{len(seen)} brands read", file=sys.stderr)
                    break
                buf, pos = buf[pos:] + more, 0
                continue
            pos = end
            brand = product.get("brand") if isinstance(product, dict) else None
            if brand is None:
                continue
            seen.add(brand)
            if brand in wanted:
                kept.setdefault(brand, []).append(product)
    return kept, seen
