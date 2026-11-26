import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import dedupe_products as D  # noqa: E402

D.photo_hashes = lambda urls: {}   # no fetching: file names only


def listing(pid, images, **kw):
    return dict(id=pid, brand='b', title='Satin-Lined Sleep Cap', images=images, available=True,
                variants=[dict(title='Black', available=True)], subs=['bonnets'], **kw)


class SameTile(unittest.TestCase):
    def test_listings_that_tile_on_one_photo_fold(self):
        a = listing('a', ['https://x/a0.png?v=1', 'https://x/same.png'], tile_image=1)
        b = listing('b', ['https://x/b0.png', 'https://x/c.png', 'https://x/same.png?v=2'], tile_image=2)
        kept, dropped = D.dedupe([a, b])
        self.assertEqual(len(kept), 1)
        self.assertEqual(len(dropped), 1)

    def test_different_tiles_stay_apart(self):
        a = listing('a', ['https://x/a0.png', 'https://x/red.png'], tile_image=1)
        b = listing('b', ['https://x/b0.png', 'https://x/blue.png'], tile_image=1)
        self.assertEqual(len(D.dedupe([a, b])[0]), 2)

    def test_a_tile_index_past_the_photos_reads_as_no_photo(self):
        self.assertEqual(D.tile(listing('a', ['https://x/a.png'], tile_image=4)), '')


class SisterStores(unittest.TestCase):
    """2026-11-26: chriscollins.com answered 429, its products were carried through
    at the end of the catalog, and all 30 lost the sister-store tie to World of
    Chris Collins. The brand stayed listed with nothing to sell and the refresh
    could not publish."""

    def candle(self, pid, brand):
        return dict(id=pid, brand=brand, title='Rhum Rose Candle', images=['https://x/rhum.png'], available=True,
                    category='home', price=60, variants=[dict(title='Default Title', available=True)], subs=[])

    def test_the_store_listed_first_keeps_a_product_both_sell(self):
        import build_catalog as bc
        brands = [dict(id='chris-collins'), dict(id='other'), dict(id='world-of-chris-collins')]
        fetched = [self.candle('o1', 'other') | dict(title='Other', images=['https://x/o.png']),
                   self.candle('w1', 'world-of-chris-collins')]
        rescued = [self.candle('c1', 'chris-collins')]          # added last, as the rescue does
        kept, _ = D.dedupe(fetched + rescued)
        self.assertEqual([p['brand'] for p in kept], ['other', 'world-of-chris-collins'], 'the bug: position decided it')
        ordered = bc.in_registry_order(fetched + rescued, brands, lambda p: p['brand'])
        self.assertEqual([p['id'] for p in ordered], ['c1', 'o1', 'w1'])
        kept, dropped = D.dedupe(ordered)
        self.assertEqual([p['id'] for p in kept], ['c1', 'o1'], 'the brand listed first keeps its shelf')
        self.assertEqual([p['id'] for p in dropped], ['w1'])

    def test_registry_order_keeps_each_brands_own_order_and_unknown_brands_last(self):
        import build_catalog as bc
        brands = [dict(id='a'), dict(id='b')]
        items = [('b', 1), ('zz', 9), ('a', 1), ('b', 2), ('a', 2)]
        self.assertEqual(bc.in_registry_order(items, brands, lambda i: i[0]),
                         [('a', 1), ('a', 2), ('b', 1), ('b', 2), ('zz', 9)])

    def test_a_brand_the_fold_empties_is_no_longer_listed(self):
        catalog = dict(brands=[dict(id='chris-collins'), dict(id='world-of-chris-collins')],
                       products=[self.candle('w1', 'world-of-chris-collins')])
        self.assertEqual(D.without_empty_brands(catalog), ['chris-collins'])
        self.assertEqual([b['id'] for b in catalog['brands']], ['world-of-chris-collins'])
        self.assertEqual(D.without_empty_brands(catalog), [], 'nothing to take out the second time')


if __name__ == '__main__':
    unittest.main()
