#!/usr/bin/env python3
"""Catalog deltas (2026-10-18): what changed in catalog-v3.json since each of
the last few published versions, so a phone that already holds one fetches
~0.5 MB instead of the whole 13.9 MB (gzipped) catalog every 6 hours.

A version is named by its fingerprint: the first 16 hex of the SHA-256 of its
exact catalog-v3.json bytes. A phone learns it by hashing what it downloaded,
or from the `to` of a delta it applied (Marracat/Stores/CatalogDelta.swift).

Published beside the catalog, under /catalog-v3/ on marracat.com:
  manifest-<fp>.json.gz   per version: its product ids in order, and a hash of
                          each product's sorted-key JSON (key order alone
                          differs between two publishes of the same products)
  manifests.txt           the kept versions' fingerprints, newest first
                          (written by the server, receiver/marracat-catalog-deltas)
  delta-<from>.json       from that version to the current one, signed (.sig)
                          like the catalog itself

A delta is the new catalog with every product the phone already has replaced
by a reference to it:
  generated_at (first key, as in the catalog), delta: 1, from, to,
  count, ids (first 16 hex of SHA-256 over the ids joined by "\n"),
  order: flat [start, n, ...]; start >= 0 takes base[start:start+n],
         start < 0 takes products[-start-1 : -start-1+n],
  categories, subcategories, brands (whole, ~100 KB gzipped), products.

  catalog_delta.py NEW_V3_JSON OUT_DIR [--manifests URL_DIR] [--keep N]
writes OUT_DIR/manifest-<fp>.json.gz, and OUT_DIR/delta-<from>.json for each
version listed at URL_DIR/manifests.txt (skipped when it would be over half
the full catalog). Nothing reachable, nothing published: the full catalog
still works on its own.
"""
import argparse, gzip, hashlib, json, os, sys, urllib.request

FORMAT = 1


def fingerprint(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


def ids_digest(ids) -> str:
    return hashlib.sha256("\n".join(ids).encode()).hexdigest()[:16]


def product_hash(p) -> str:
    return hashlib.sha256(json.dumps(p, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()[:16]


def manifest(catalog, fp, hashes=None):
    ps = catalog["products"]
    return {"fp": fp, "generated_at": catalog["generated_at"], "ids": [p["id"] for p in ps],
            "hashes": hashes if hashes is not None else [product_hash(p) for p in ps]}


def make_delta(base, catalog, fp, hashes=None):
    """The delta from `base` (a manifest) to `catalog`, whose own fingerprint is `fp`."""
    first = {}
    for i, pid in enumerate(base["ids"]):
        first.setdefault(pid, i)
    hashes = hashes if hashes is not None else [product_hash(p) for p in catalog["products"]]
    order, products = [], []

    def take(start, delta):
        # Extend the last run when this item follows it directly.
        if order:
            s, n = order[-2], order[-1]
            if delta and s < 0 and -s - 1 + n == -start - 1 or not delta and s >= 0 and s + n == start:
                order[-1] += 1
                return
        order.extend([start, 1])

    for p, h in zip(catalog["products"], hashes):
        i = first.get(p["id"])
        if i is not None and base["hashes"][i] == h:
            take(i, False)
        else:
            products.append(p)
            take(-len(products), True)
    out = {"generated_at": catalog["generated_at"], "delta": FORMAT, "from": base["fp"], "to": fp,
           "count": len(catalog["products"]), "ids": ids_digest(p["id"] for p in catalog["products"]),
           "order": order}
    for k in ("categories", "subcategories", "brands"):
        out[k] = catalog[k]
    out["products"] = products
    return out


def apply(base_catalog, delta):
    """The reference apply, for tests: CatalogDelta.swift does the same."""
    base = base_catalog["products"]
    out = []
    order = delta["order"]
    for k in range(0, len(order), 2):
        start, n = order[k], order[k + 1]
        if start >= 0:
            assert start + n <= len(base)
            out.extend(base[start:start + n])
        else:
            j = -start - 1
            assert j + n <= len(delta["products"])
            out.extend(delta["products"][j:j + n])
    assert len(out) == delta["count"] and ids_digest(p["id"] for p in out) == delta["ids"]
    c = {"generated_at": delta["generated_at"]}
    for k in ("categories", "subcategories", "brands"):
        c[k] = delta[k]
    c["products"] = out
    return c


def dump(obj) -> bytes:
    # The published catalog's own spelling: compact, UTF-8, generated_at first.
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "marracat-publish"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("out")
    ap.add_argument("--manifests", default="https://marracat.com/catalog-v3")
    ap.add_argument("--keep", type=int, default=8)
    a = ap.parse_args()
    data = open(a.catalog, "rb").read()
    fp = fingerprint(data)
    catalog = json.loads(data)
    del data
    hashes = [product_hash(p) for p in catalog["products"]]
    os.makedirs(a.out, exist_ok=True)
    with gzip.open(os.path.join(a.out, f"manifest-{fp}.json.gz"), "wb", compresslevel=6) as f:
        f.write(dump(manifest(catalog, fp, hashes)))
    full = os.path.getsize(a.catalog)
    try:
        listed = [l.strip() for l in fetch(f"{a.manifests}/manifests.txt").decode().splitlines()]
    except Exception as e:  # first publish, or the server is unreachable
        print(f"deltas: no manifests listed ({e}); full catalog only")
        listed = []
    made = 0
    for base_fp in [l for l in listed if len(l) == 16 and l != fp][: a.keep]:
        try:
            base = json.loads(gzip.decompress(fetch(f"{a.manifests}/manifest-{base_fp}.json.gz")))
        except Exception as e:
            print(f"deltas: manifest {base_fp} unreadable ({e}); skipped")
            continue
        if base.get("fp") != base_fp:
            print(f"deltas: manifest {base_fp} names {base.get('fp')}; skipped")
            continue
        blob = dump(make_delta(base, catalog, fp, hashes))
        if len(blob) > full // 2:
            print(f"deltas: from {base_fp} would be {len(blob) // 1_000_000} MB; full catalog instead")
            continue
        open(os.path.join(a.out, f"delta-{base_fp}.json"), "wb").write(blob)
        made += 1
        print(f"deltas: from {base_fp} ({base['generated_at']}): {len(blob) / 1e6:.1f} MB")
    print(f"deltas: {made} made for {fp} ({catalog['generated_at']})")


if __name__ == "__main__":
    sys.exit(main())
