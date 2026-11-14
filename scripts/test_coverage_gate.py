"""ship.sh's coverage gate: every screen file is executed by some test."""
import contextlib
import io
import json
import unittest
from types import SimpleNamespace
from unittest import mock

import coverage_gate as cg


def report(*targets):
    return SimpleNamespace(stdout=json.dumps({"targets": [{"files": [{"path": p, "coveredLines": n} for p, n in t]} for t in targets]}))


def gate(*targets):
    out = io.StringIO()
    with mock.patch.object(cg.subprocess, "run", return_value=report(*targets)), \
         mock.patch("sys.argv", ["coverage_gate.py", "Ship.xcresult"]), contextlib.redirect_stdout(out):
        return cg.main(), out.getvalue()


ROOT = "/Users/x/Marracat/Marracat"


class CoverageGate(unittest.TestCase):
    def test_every_screen_touched_passes(self):
        code, out = gate([(f"{ROOT}/Views/HomeView.swift", 120), (f"{ROOT}/Checkout/WooCheckoutSheet.swift", 4)])
        self.assertEqual(code, 0)
        self.assertIn("2/2 screen files", out)

    def test_an_untouched_screen_fails_and_is_named(self):
        code, out = gate([(f"{ROOT}/Views/HomeView.swift", 120), (f"{ROOT}/Views/FeaturedBanner.swift", 0)])
        self.assertEqual(code, 1)
        self.assertIn("Marracat/Views/FeaturedBanner.swift", out)

    def test_a_screen_counts_if_any_target_ran_it(self):
        self.assertEqual(gate([(f"{ROOT}/Views/OrdersView.swift", 0)], [(f"{ROOT}/Views/OrdersView.swift", 9)])[0], 0)

    def test_only_screen_files_count(self):
        code, _ = gate([(f"{ROOT}/Stores/CatalogStore.swift", 0), (f"{ROOT}/Views/HomeView.swift", 3),
                        (f"{ROOT}/Checkout/CheckoutCoordinator.swift", 0), (f"{ROOT}/Social/SocialViews.swift", 2)])
        self.assertEqual(code, 0)

    def test_a_report_without_screens_means_coverage_was_off(self):
        code, out = gate([(f"{ROOT}/Stores/CatalogStore.swift", 10)])
        self.assertEqual(code, 1)
        self.assertIn("enableCodeCoverage", out)


if __name__ == "__main__":
    unittest.main()
