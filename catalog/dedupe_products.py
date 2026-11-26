#!/usr/bin/env python3
"""One tile per product: fold a brand's repeat listings of the same thing into one.

Stores often publish one product several times: the same listing twice (Glo Melanin's
face wash, three times), one listing per ring or bed size (Lola Ade, Linoto), paperback
and hardcover as separate products (Jacaranda Books), or a wholesale twin next to the
retail listing (Trill Paws tags). In a subcategory grid every one of those reads as a
duplicate.

Two listings are the same product when they share a brand, a title and a main photo:
either the same photo file, or photos that look the same (a tiny thumbnail of each is
compared; hashes are cached in catalog/photo_hashes.json). Colourways, where the photo
shows a different colour, stay separate products.

The best listing stays (in stock, most sizes available, lowest price, first in the feed)
and takes on the others' options, so no size or format is lost: a hardcover becomes a
"Hardcover" option on the paperback's page. Cart permalinks take any variant id from the
same store, so the merged options check out as before. A listing whose product type says
"wholesale" is dropped outright when a retail twin exists.

brands.json keeps every listing's handle on purpose: the folded listings are what the
merged options come from, so build_catalog.py runs this fold on every build.

Usage: python3 catalog/dedupe_products.py [--check]   (--check reports without writing)
"""
import io, json, re, sys, urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from catalog_io import write_catalog

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'Marracat/Resources/catalog.json'
HASHES = ROOT / 'catalog/photo_hashes.json'

# Thumbnail distance under which two photos are the same picture. Measured on the
# catalog 2026-09-22: re-uploads of one photo score 0-0.4; the closest colourways
# (Almasika's yellow vs rose gold huggies, Nia bags) score 0.58 and up.
SAME_SHAPE, SAME_COLOUR = 2, 0.45


def norm_title(p):
    return re.sub(r'[^a-z0-9]', '', (p.get('title') or '').lower())


def photo(p, i=0):
    images = p.get('images') or ['']
    return re.sub(r'\?.*$', '', images[i] if i < len(images) else '')


def tile(p):
    """The photo a grid shows (catalog/photo_roles.py's tile_image, else the first)."""
    return photo(p, p.get('tile_image') or 0)


def thumb(url):
    """(9x8 grey, 8x8 RGB) pixel lists of a photo, or None."""
    from PIL import Image
    src = url + ('?width=96' if 'shopify' in url or '/cdn/shop/' in url else '')
    try:
        req = urllib.request.Request(src, headers={'User-Agent': 'Mozilla/5.0'})
        im = Image.open(io.BytesIO(urllib.request.urlopen(req, timeout=20).read())).convert('RGB')
        # tobytes, not getdata (deprecated in Pillow 13, gone in 14): the same values, flattened.
        return [list(im.resize((9, 8)).convert('L').tobytes()), list(im.resize((8, 8)).tobytes())]
    except Exception:
        return None


def looks_same(a, b):
    grey_a = [a[0][r * 9 + i] > a[0][r * 9 + i + 1] for r in range(8) for i in range(8)]
    grey_b = [b[0][r * 9 + i] > b[0][r * 9 + i + 1] for r in range(8) for i in range(8)]
    shape = sum(x != y for x, y in zip(grey_a, grey_b))
    colour = sum(abs(x - y) for x, y in zip(a[1], b[1])) / len(a[1])
    return shape <= SAME_SHAPE and colour < SAME_COLOUR


def photo_hashes(urls):
    """Cached thumbnails; fetches the missing ones when Pillow is installed."""
    cache = json.loads(HASHES.read_text()) if HASHES.exists() else {}
    missing = [u for u in urls if u not in cache]
    if missing:
        try:
            import PIL  # noqa: F401
        except ImportError:
            print(f'dedupe: Pillow not installed, {len(missing)} photos compared by file name only')
            return cache
        with ThreadPoolExecutor(24) as ex:
            for u, t in zip(missing, ex.map(thumb, missing)):
                if t: cache[u] = t
        HASHES.write_text(json.dumps(cache, separators=(',', ':')))
    return cache


def rank(indexed):
    i, p = indexed
    avail = [v for v in p.get('variants', []) if v.get('available')]
    return (not p.get('available'), -len(avail), p.get('price') or 0, i)


def same_product_groups(products, across_brands=False):
    """Lists of (index, product) that are one product listed more than once."""
    by_title = defaultdict(list)
    for i, p in enumerate(products):
        if norm_title(p) and photo(p):
            by_title[norm_title(p) if across_brands else (p['brand'], norm_title(p))].append((i, p))
    if across_brands:
        by_title = {k: m for k, m in by_title.items() if len({p['brand'] for _, p in m}) > 1}
    candidates = [m for m in by_title.values() if len(m) > 1]
    cache = photo_hashes(sorted({photo(p) for m in candidates for _, p in m}))

    groups = []
    for members in candidates:
        # Union listings whose photos are the same file or look the same.
        parent = list(range(len(members)))
        def find(x):
            while parent[x] != x:
                parent[x] = parent[parent[x]]; x = parent[x]
            return x
        for a in range(len(members)):
            for b in range(a + 1, len(members)):
                pa, pb = photo(members[a][1]), photo(members[b][1])
                ta, tb = cache.get(pa), cache.get(pb)
                # The same tile file counts too: Hairbrella's two "Satin-Lined Sleep
                # Cap" listings open on different photos but both tile on one
                # (2026-10-25), so a grid showed the same tile twice.
                if pa == pb or tile(members[a][1]) == tile(members[b][1]) or (ta and tb and looks_same(ta, tb)):
                    parent[find(a)] = find(b)
        sets = defaultdict(list)
        for k, m in enumerate(members): sets[find(k)].append(m)
        groups += [s for s in sets.values() if len(s) > 1]
    return groups


def wholesale(p):
    return 'wholesale' in (p.get('product_type') or '').lower()


def merge(group):
    """The kept product (with the others' options folded in) and the ids folded away."""
    retail = [m for m in group if not wholesale(m[1])] or group
    keep = dict(min(retail, key=rank)[1])
    others = [p for _, p in sorted(retail, key=rank)[1:]]
    variants = [dict(v) for v in keep.get('variants', [])]
    label = lambda p: (p.get('product_type') or '').strip()
    single = lambda p: all(v['title'] == 'Default Title' for v in p.get('variants', []))
    # "24\" / GOLD" and "GOLD / 24\"" are the same option.
    same = lambda a, b: sorted(a.lower().split(' / ')) == sorted(b.lower().split(' / '))

    for other in others:
        for v in other.get('variants', []):
            title = v['title']
            if title == 'Default Title':
                # Two one-option listings (Paperback / Hardcover): the product types
                # name them. Otherwise nothing names the difference: same offer.
                title = label(other)
                if not (single(keep) and title and label(keep) and title != label(keep)):
                    continue
                for x in variants:
                    if x['title'] == 'Default Title': x['title'] = label(keep)
            if any(same(x['title'], title) for x in variants):
                continue
            variants.append({**v, 'title': title})
    keep['variants'] = variants
    keep['available'] = any(v.get('available') for v in variants)
    keep['subs'] = sorted({s for _, p in group for s in (p.get('subs') or [])}) or keep.get('subs')
    return keep, {p['id'] for _, p in group if p['id'] != keep['id']}


def dedupe(products, brand_categories=None):
    """(new product list, folded-away products).

    brand_categories ({brand id: category}) settles sister stores that carry the same
    product (Harlem Candle Co and Harlem Perfume, Fenty Beauty and Fenty Hair): the store
    whose category matches the product keeps it. Their options can't merge, since a cart
    permalink only takes its own store's variants."""
    replaced, folded = {}, set()
    for group in same_product_groups(products):
        keep, gone = merge(group)
        replaced[keep['id']] = keep
        folded |= gone
    products2 = [replaced.get(p['id'], p) for p in products if p['id'] not in folded]
    cats = brand_categories or {}
    for group in same_product_groups(products2, across_brands=True):
        if len({p['brand'] for _, p in group}) < 2:
            continue
        home = lambda m: (cats.get(m[1]['brand']) != m[1].get('category'), rank(m))
        keep = min(group, key=home)[1]
        folded |= {p['id'] for _, p in group if p['brand'] != keep['brand']}
    dropped = [p for p in products if p['id'] in folded]
    return [p for p in products2 if p['id'] not in folded], dropped


def without_empty_brands(catalog):
    """Takes out of catalog['brands'] any brand the fold left with nothing to sell, and
    returns their ids. A brand with no products is not a shelf (build_catalog.py leaves
    such brands out too); a sister store can take every product a brand has, and the
    app, the site and the web tests all expect the brand list to match the products."""
    selling = {p['brand'] for p in catalog['products']}
    emptied = [b['id'] for b in catalog['brands'] if b['id'] not in selling]
    catalog['brands'] = [b for b in catalog['brands'] if b['id'] in selling]
    return emptied


def main():
    catalog = json.loads(CATALOG.read_text())
    products, dropped = dedupe(catalog['products'], {b['id']: b.get('category') for b in catalog['brands']})
    print(f'dedupe: {len(dropped)} repeat listings folded into their products')
    if '--check' in sys.argv or not dropped:
        return
    catalog['products'] = products
    emptied = without_empty_brands(catalog)
    write_catalog(CATALOG, catalog)
    print('by brand:', Counter(p['brand'] for p in dropped).most_common(12))
    if emptied:
        print('no longer listed, every product folded into a sister store:', ', '.join(emptied))


if __name__ == '__main__':
    main()
