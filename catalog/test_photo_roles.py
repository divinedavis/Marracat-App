import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import photo_roles as R  # noqa: E402

PACKSHOT, LIFESTYLE, CHART = [1.0, 0.4], [0.2, 0.9], [1.0, 0.05]


class Pick(unittest.TestCase):
    def test_a_good_first_photo_stays_the_tile(self):
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE + [0.9]]), (0, 1))

    def test_a_lifestyle_first_photo_gives_way_to_a_packshot(self):
        self.assertEqual(R.pick([LIFESTYLE, CHART, PACKSHOT])[0], 2)

    def test_a_size_chart_is_never_the_tile(self):
        self.assertEqual(R.pick([LIFESTYLE, CHART]), (0, 0))

    def test_a_flat_first_photo_of_a_thin_product_stays(self):
        self.assertEqual(R.pick([CHART, PACKSHOT])[0], 0)

    def test_a_hero_needs_the_models_yes(self):
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE])[1], 0)
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE + [0.3]])[1], 0)
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE + [0.8]])[1], 1)

    def test_an_s4_score_uses_s4s_cut_off(self):
        # 0.5 passes S4's 0.47 but not S0's 0.6.
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE + [0.5, R.CLIP_MARK]])[1], 1)
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE + [0.5]])[1], 0)
        self.assertEqual(R.pick([PACKSHOT, LIFESTYLE + [0.4, R.CLIP_MARK]])[1], 0)


try:
    import PIL  # noqa: F401
except ImportError:  # the system python3 that run_tests.sh uses has no Pillow
    PIL = None


@unittest.skipIf(PIL is None, "Pillow not installed")
class Stats(unittest.TestCase):
    def test_even_border_and_cover(self):
        from PIL import Image, ImageDraw
        im = Image.new("RGB", (64, 64), "white")
        ImageDraw.Draw(im).rectangle([16, 16, 48, 48], fill="black")
        even, cover = R.stats(im)
        self.assertEqual(even, 1.0)
        self.assertAlmostEqual(cover, 33 * 33 / 4096, places=2)
        self.assertEqual(R.role([even, cover]), "product")
        noisy = Image.effect_noise((64, 64), 120).convert("RGB")
        self.assertEqual(R.role(R.stats(noisy)), "lifestyle")


class Annotate(unittest.TestCase):
    def test_fields_only_when_not_zero_and_unlabelled_products_untouched(self):
        a = dict(images=["https://x/a.jpg", "https://x/b.jpg"], tile_image=1)
        b = dict(images=["https://x/c.jpg", "https://x/d.jpg"])
        cache = {R.key("https://x/a.jpg"): LIFESTYLE + [0.9], R.key("https://x/b.jpg"): PACKSHOT}
        R.annotate([a, b], cache)
        self.assertEqual((a.get("tile_image"), a.get("hero_image")), (1, None))
        self.assertNotIn("tile_image", b)

    def test_only_https_photos_are_fetched(self):
        self.assertIsNone(R.fetch("http://example.com/a.jpg"))
        self.assertIsNone(R.fetch("file:///etc/passwd"))


if __name__ == "__main__":
    unittest.main()
