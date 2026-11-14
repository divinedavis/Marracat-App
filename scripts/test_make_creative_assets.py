"""Copy and size checks for scripts/make_creative_assets.py.

Reads the generator's tables with ast (no Pillow needed; run_tests.sh uses the
system python3) and checks what Apple review would catch: banned copy and
canvas sizes.
"""
import ast
import pathlib
import re
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "make_creative_assets.py"


def tables():
    out = {}
    for node in ast.parse(SRC.read_text()).body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name in {"CANVASES", "PAGES", "VIDEO_LINES", "SAFE", "LAYOUT"}:
                out[name] = ast.literal_eval(node.value)
    return out


T = tables()


class CreativeAssets(unittest.TestCase):
    def test_canvases_are_apples_sizes(self):
        self.assertEqual(T["CANVASES"], {"header": (3840, 1646), "search": (3840, 2560),
                                         "universal": (5244, 2950)})

    def test_safe_areas_are_apples_template(self):
        # "ART SAFE AREA" in creative_assets-templates.sketch (2026-10-12). The
        # first header ignored it and an iPhone 17 Pro cropped the name.
        self.assertEqual(T["SAFE"], {"header": (1097, 493, 1646, 661), "search": (836, 765, 2168, 1030),
                                     "universal": (1921, 660, 1402, 962)})
        for kind, (x, y, w, h) in T["SAFE"].items():
            cw, ch = T["CANVASES"][kind]
            self.assertLessEqual(abs((x + w / 2) - cw / 2), 1, kind)  # centred across
            self.assertTrue(0 <= y and y + h <= ch, kind)

    def test_layout_stays_inside_the_safe_area(self):
        for kind, L in T["LAYOUT"].items():
            for key in ("name_cy", "rule_cy", "line_cy", "name_w", "line_w"):
                self.assertTrue(0 < L[key] <= 1, f"{kind} {key}")
            self.assertLess(L["name_cy"], L["rule_cy"], kind)
            self.assertLess(L["rule_cy"], L["line_cy"], kind)
        # The header's top half is where the App Store's back and mute/share
        # buttons sit on every iPhone: the name starts below them.
        self.assertGreaterEqual(T["LAYOUT"]["header"]["name_cy"], 0.45)

    def test_pages_are_default_plus_custom_product_pages(self):
        self.assertIn("default", T["PAGES"])
        for slug in T["PAGES"]:
            self.assertTrue(slug == "default" or slug.startswith("cpp-"), slug)

    def test_type_only_no_photos(self):
        # Owner's call 2026-10-06: name, rule and line on white, no product photos.
        self.assertNotIn("Image.open", SRC.read_text())

    def test_copy_follows_the_asset_rules(self):
        banned = re.compile(r"independent|\$|%|#1|\bbest\b|\bfree\b|https?:|www\.|\.com|©|app store|google play",
                            re.I)
        for slug, page in T["PAGES"].items():
            self.assertIsNone(banned.search(page["line"]), f"{slug}: {page['line']}")
            self.assertLessEqual(len(page["line"]), 40, slug)
        for line in T["VIDEO_LINES"]:
            self.assertIsNone(banned.search(line), line)
            self.assertLessEqual(len(line), 40, line)


if __name__ == "__main__":
    unittest.main()
