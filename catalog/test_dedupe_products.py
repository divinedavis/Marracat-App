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


if __name__ == '__main__':
    unittest.main()
