#!/usr/bin/env python3
"""Record each Shopify brand's UCP checkout endpoint in catalog/brands.json.

A Shopify store publishes its Universal Commerce Protocol profile at
/.well-known/ucp; the MCP endpoint in it is where the app creates checkouts
(see Marracat/Checkout/UCP.swift). The endpoint's host can differ from the
storefront domain, so it is looked up here rather than guessed. Brands whose
profile is missing lose the field and fall back to the cart-permalink checkout.

Usage: python3 catalog/ucp_endpoints.py [--catalog]   (--catalog also stamps the bundled catalog.json)
"""
import json, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from catalog_io import write_catalog

ROOT = Path(__file__).resolve().parent.parent
BRANDS, CATALOG = ROOT / 'catalog/brands.json', ROOT / 'Marracat/Resources/catalog.json'
UA = 'Mozilla/5.0 (compatible; Marracat catalog builder)'


def endpoint(domain):
    # One slow or rate-limited answer used to drop a store's endpoint until the
    # next run (Amania Afrik, 2026-09-24), which hid "Check out all" for any cart
    # holding it. Three tries before calling a store unsupported.
    for attempt in range(3):
        found = _endpoint_once(domain)
        if found:
            return found
        time.sleep(1 + attempt)
    return None


def _endpoint_once(domain):
    try:
        req = urllib.request.Request(f'https://{domain}/.well-known/ucp', headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read(200_000))
        return next(s['endpoint'] for s in d['ucp']['services']['dev.ucp.shopping'] if s.get('transport') == 'mcp')
    except Exception:  # noqa: BLE001 — no profile, not Shopify, or offline: no endpoint
        return None


def main():
    brands = json.loads(BRANDS.read_text())
    shopify = [b for b in brands if b.get('shopify') and b.get('platform', 'shopify') == 'shopify']
    with ThreadPoolExecutor(16) as ex:
        found = dict(zip((b['id'] for b in shopify), ex.map(lambda b: endpoint(b['domain']), shopify)))
    for b in brands:
        ep = found.get(b['id'])
        if ep:
            b['ucp'] = ep
        else:
            b.pop('ucp', None)
    BRANDS.write_text(json.dumps(brands, indent=1, ensure_ascii=False) + '\n')
    print(f'{sum(1 for v in found.values() if v)} of {len(shopify)} Shopify brands have a UCP endpoint')
    if '--catalog' in sys.argv:
        catalog = json.loads(CATALOG.read_text())
        by = {b['id']: b.get('ucp') for b in brands}
        for b in catalog['brands']:
            if by.get(b['id']):
                b['ucp'] = by[b['id']]
            else:
                b.pop('ucp', None)
        write_catalog(CATALOG, catalog)
        print('stamped catalog.json')


if __name__ == '__main__':
    main()
