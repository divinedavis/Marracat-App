#!/usr/bin/env python3
"""Count distinct stocked brands in every catalog category and taxonomy aisle."""
import argparse
import collections
import csv
import json
from pathlib import Path
from taxonomy import flat_subcategories

ROOT = Path(__file__).resolve().parent.parent

def coverage(catalog):
    all_brands, stocked = collections.defaultdict(set), collections.defaultdict(set)
    buy_now = collections.defaultdict(set)
    brands = {b['id']: b for b in catalog['brands']}
    for product in catalog['products']:
        brand = brands.get(product['brand'], {})
        supports_buy_now = (brand.get('shopify') is True
                            and brand.get('platform', 'shopify') == 'shopify'
                            and product.get('available') is True
                            and bool(product.get('images'))
                            and any(v.get('available') is True and v.get('price', 0) > 0
                                    for v in product.get('variants', [])))
        keys = [product['category']] + [product['category'] + ':' + s for s in product.get('subs', [])]
        for key in keys:
            all_brands[key].add(product['brand'])
            if product.get('available'):
                stocked[key].add(product['brand'])
            if supports_buy_now:
                buy_now[key].add(product['brand'])
    rows = []
    for kind, items in [('category', catalog['categories']), ('subcategory', flat_subcategories())]:
        for item in items:
            key = item['id']
            rows.append(dict(kind=kind, id=key, name=item['name'],
                             category=item.get('category', key),
                             listed_brands=len(all_brands[key]),
                             stocked_brands=len(stocked[key]),
                             missing_to_ten=max(0, 10-len(stocked[key])),
                             brand_ids=sorted(stocked[key]),
                             buy_now_brands=len(buy_now[key]),
                             missing_buy_now_to_ten=max(0, 10-len(buy_now[key])),
                             buy_now_brand_ids=sorted(buy_now[key])))
    return rows

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=ROOT/'Marracat/Resources/catalog.json')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    rows = coverage(catalog)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output/'coverage.json').write_text(json.dumps(dict(generated_at=catalog['generated_at'],
        definition='Unique brand IDs per aisle. Stocked means available in the feed. Buy Now additionally requires Shopify checkout support, an image, and an available positive-price variant. Includes empty taxonomy aisles. This count does not independently verify ownership, live checkout, or physical inventory.',
        rows=rows), indent=2)+'\n')
    with (args.output/'coverage.csv').open('w') as f:
        writer = csv.DictWriter(f, fieldnames=['kind','id','name','category','listed_brands','stocked_brands','missing_to_ten','brand_ids','buy_now_brands','missing_buy_now_to_ten','buy_now_brand_ids'], lineterminator='\n')
        writer.writeheader()
        for row in rows:
            writer.writerow(dict(row, brand_ids=';'.join(row['brand_ids']),
                                 buy_now_brand_ids=';'.join(row['buy_now_brand_ids'])))
    for kind in ('category','subcategory'):
        subset=[r for r in rows if r['kind']==kind]
        print(f"{kind}: {len(subset)} total; {sum(r['stocked_brands']>=10 for r in subset)} at ten; {sum(r['stocked_brands']<10 for r in subset)} below ten")
        print(f"  Buy Now: {sum(r['buy_now_brands']>=10 for r in subset)} at ten; {sum(r['buy_now_brands']<10 for r in subset)} below ten")
        if kind=='category':
            for row in subset:
                if row['stocked_brands']<10: print(f"  {row['name']}: {row['stocked_brands']} stocked brands, needs {row['missing_to_ten']}")

if __name__ == '__main__': main()
