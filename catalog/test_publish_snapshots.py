import unittest
from publish_snapshots import compact_product, legacy_catalog

class LegacyCatalogTests(unittest.TestCase):
    def test_foreign_prices_never_reach_dollar_only_clients(self):
        catalog = dict(brands=[dict(id='us'), dict(id='uk', currency='GBP'), dict(id='fr', currency='EUR')],
                       products=[dict(id=c, brand=c, category='clothing', subs=['tops'], **extra)
                                 for c, extra in [('us', {}), ('uk', {'currency': 'GBP'}), ('fr', {'currency': 'EUR'})]],
                       subcategories=[dict(id='clothing:tops'), dict(id='shoes:boots')])
        legacy = legacy_catalog(catalog)
        self.assertEqual([b['id'] for b in legacy['brands']], ['us'])
        self.assertEqual([p['id'] for p in legacy['products']], ['us'])
        self.assertEqual(legacy['subcategories'], [dict(id='clothing:tops')])
        self.assertEqual(len(catalog['products']), 3)

class CompactTests(unittest.TestCase):
    def test_the_bundle_photo_is_the_tile_and_new_fields_travel(self):
        p = dict(id='a', brand='b', images=['0.jpg', '1.jpg', '2.jpg'], tile_image=2, hero_image=1,
                 attrs={'hair': ['4c']}, group='b:1', color='Sand', swatch='#d4c3a0', variants=[], description='x')
        row = compact_product(p)
        self.assertEqual(row['images'], ['2.jpg'])
        self.assertNotIn('tile_image', row)
        self.assertEqual((row['hero_image'], row['attrs'], row['group'], row['color'], row['swatch']),
                         (1, {'hair': ['4c']}, 'b:1', 'Sand', '#d4c3a0'))

    def test_option_names_stay_with_the_variants_on_the_product_page(self):
        row = compact_product(dict(id='a', images=['0.jpg'], option_names=['Color', 'Size'],
                                   variants=[dict(title='Black / S'), dict(title='Black / M')]))
        self.assertNotIn('option_names', row)
        self.assertEqual(row['opts'], ['black', 's', 'm'])

    def test_a_bad_tile_index_falls_back_to_the_first_photo(self):
        self.assertEqual(compact_product(dict(id='a', images=['0.jpg'], tile_image=5))['images'], ['0.jpg'])


if __name__ == '__main__':
    unittest.main()
