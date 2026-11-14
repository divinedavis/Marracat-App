"""Every Image("…") in the widget extension has an image set in its own
asset catalog.

The extension can't see the app's Assets.xcassets; a missing name renders
nothing on the Lock Screen and no compiler or unit test notices. Added with
the Marracat logo on the delivery Live Activity (2026-10-17); the Dynamic
Island's small slots draw the tab bar's M from Shared/.
"""
from __future__ import annotations

import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WIDGETS = ROOT / "MarracatWidgets"
CATALOG = WIDGETS / "Assets.xcassets"


def png_size(path: Path) -> tuple[int, int]:
    head = path.read_bytes()[:24]
    assert head[:8] == b"\x89PNG\r\n\x1a\n", f"{path} is not a PNG"
    return struct.unpack(">II", head[16:24])


class WidgetAssetsTest(unittest.TestCase):
    def test_every_named_image_is_in_the_widget_catalog(self):
        names = set()
        for swift in WIDGETS.glob("*.swift"):
            names |= set(re.findall(r'\bImage\("([^"]+)"\)', swift.read_text()))
        self.assertIn("MarracatLogo", names, "the Live Activity shows the logo")
        for name in sorted(names):
            imageset = CATALOG / f"{name}.imageset"
            self.assertTrue(imageset.is_dir(), f"{name} missing from {CATALOG}")
            pngs = list(imageset.glob("*.png"))
            self.assertTrue(pngs, f"{name} has no image file")

    def test_island_draws_the_tab_bar_m_from_shared_code(self):
        # The widget can't link the app, so the M must live in Shared/ once.
        defs = [f for f in ROOT.glob("*/*.swift") if "struct MarracatMark: Shape" in f.read_text()]
        self.assertEqual([f.relative_to(ROOT).as_posix() for f in defs], ["Shared/MarracatMark.swift"])
        self.assertIn("MarracatMark()", (WIDGETS / "DeliveryLiveActivity.swift").read_text())

    def test_logo_is_sharp_at_lock_screen_size(self):
        # Drawn at up to 34 pt; 3x screens need 102 px.
        w, h = png_size(CATALOG / "MarracatLogo.imageset" / "marracat-logo.png")
        self.assertEqual(w, h)
        self.assertGreaterEqual(w, 102)


if __name__ == "__main__":
    unittest.main()
