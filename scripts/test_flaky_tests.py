import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import flaky_tests as F  # noqa: E402


class Tiers(unittest.TestCase):
    def setUp(self):
        d = pathlib.Path(tempfile.mkdtemp())
        F.FAST, F.QUARANTINE = d / "fast.txt", d / "q.txt"
        F.FAST.write_text("# set\nA/testOne\nA/testTwo\n")
        F.QUARANTINE.write_text("# head\nA/testTwo\nB/testThree\n")

    def test_fast_runs_unit_tests_and_its_list_minus_quarantine(self):
        a = F.args("fast")
        self.assertIn("-only-testing:MarracatTests", a)
        self.assertIn("-only-testing:MarracatUITests/A/testOne", a)
        self.assertIn("-skip-testing:MarracatUITests/A/testTwo", a)

    def test_full_only_skips_the_quarantine(self):
        self.assertEqual(F.args("full"), ["-skip-testing:MarracatUITests/A/testTwo", "-skip-testing:MarracatUITests/B/testThree"])

    def test_the_quarantine_pass_keeps_to_the_tier(self):
        self.assertEqual(F.quarantined("fast"), ["-only-testing:MarracatUITests/A/testTwo"])
        self.assertEqual(len(F.quarantined("full")), 2)

    def test_the_real_lists_parse(self):
        root = pathlib.Path(__file__).resolve().parent.parent
        fast = F.names(root / "MarracatUITests/fast-tests.txt")
        self.assertGreater(len(fast), 10)
        self.assertTrue(all("/test" in t for t in fast + F.names(root / "MarracatUITests/quarantine.txt")))


class Quarantine(unittest.TestCase):
    def test_two_flags_in_five_ships_quarantine_a_test(self):
        h = [{"flagged": ["A/x"]}, {"flagged": []}, {"flagged": ["A/x", "A/y"]}]
        keep, added, removed = F.update(h, [])
        self.assertEqual((keep, added, removed), (["A/x"], ["A/x"], []))

    def test_a_flag_older_than_five_ships_doesnt_count(self):
        h = [{"flagged": ["A/x"]}] + [{"flagged": []}] * 4 + [{"flagged": ["A/x"]}]
        self.assertEqual(F.update(h, [])[1], [])

    def test_five_clean_quarantine_runs_release_a_test(self):
        h = [{"flagged": [], "quarantine": {"A/x": "retried"}}] + [{"flagged": [], "quarantine": {"A/x": "pass"}}] * 5
        self.assertEqual(F.update(h, ["A/x"]), ([], [], ["A/x"]))
        self.assertEqual(F.update(h[:-1], ["A/x"])[2], [])


if __name__ == "__main__":
    unittest.main()
