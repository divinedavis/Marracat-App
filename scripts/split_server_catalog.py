#!/usr/bin/env python3
"""Split the catalog for marracat.com's Node server (web/deploy.sh runs this).

The server used to JSON.parse the whole catalog and keep every product in
full, descriptions and all: at 120,873 products (250 MB of JSON) that needed
more than 1.5 GB of heap on a 2 GB droplet whose Node limit is ~1 GB, and it
crashed on start (2026-10-02). Now it gets two files:

  catalog-slim.json        each product with only what the product grid,
                           search, the home page, restock checks and share
                           previews read (server/catalog.js), held in memory.
  product-details.sqlite   each product in full, keyed by id, read one row at
                           a time for /api/products/:id.

    python3 scripts/split_server_catalog.py <catalog.json> <out dir>
"""
import json
import os
import sqlite3
import sys

# What server/catalog.js reads from a product outside /api/products/:id.
SLIM = ("id", "brand", "title", "category", "price", "currency", "compare_at", "available",
        "product_type", "tags", "published_at", "best_rank", "clean", "metal", "scent", "safer", "food", "baby", "fiber", "fabric", "lab", "pet",
        "material", "home", "subs",
        "url",
        # Shopper filters, colourways (catalog/attributes.py, colorways.py).
        "attrs", "group", "color", "swatch")


def slim(product):
    out = {k: product[k] for k in SLIM if k in product}
    images = product.get("images") or []
    # The grid's one photo is the tile; the hero, when there is one, is the
    # photo a banner shows (catalog/photo_roles.py).
    tile, hero = product.get("tile_image") or 0, product.get("hero_image") or 0
    out["images"] = [images[tile if 0 <= tile < len(images) else 0]] if images else []
    if 0 < hero < len(images):
        out["hero"] = images[hero]
    variants = product.get("variants") or []
    # The grid adds a single-variant product straight to the cart; a product
    # with options goes through its page, which reads the details row.
    out["variants"] = variants if len(variants) == 1 else []
    return out


def main(source, out_dir):
    with open(source, encoding="utf-8") as f:
        catalog = json.load(f)
    products = catalog["products"]

    db_path = os.path.join(out_dir, "product-details.sqlite")
    tmp = db_path + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.execute("CREATE TABLE product_details (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
    db.executemany("INSERT OR REPLACE INTO product_details VALUES (?, ?)",
                   ((p["id"], json.dumps(p, ensure_ascii=False, separators=(",", ":"))) for p in products))
    db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    db.execute("INSERT INTO meta VALUES ('generated_at', ?)", (catalog.get("generated_at", ""),))
    db.commit()
    db.close()
    os.replace(tmp, db_path)

    catalog["products"] = [slim(p) for p in products]
    slim_path = os.path.join(out_dir, "catalog-slim.json")
    with open(slim_path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(slim_path + ".tmp", slim_path)
    print(f"server catalog: {len(products)} products, "
          f"slim {os.path.getsize(slim_path) / 1e6:.0f} MB, details {os.path.getsize(db_path) / 1e6:.0f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
