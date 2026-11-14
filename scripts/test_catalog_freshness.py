"""scripts/catalog_freshness.py: when ship.sh may bundle the droplet's catalog as is."""
import datetime
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import catalog_freshness as f  # noqa: E402

UTC = datetime.timezone.utc
NOW = datetime.datetime(2026, 11, 10, 8, 0, tzinfo=UTC)


def hours_ago(h):
    return NOW - datetime.timedelta(hours=h)


class Freshness(unittest.TestCase):
    def test_within_six_hours_is_fresh(self):
        self.assertEqual(f.verdict(hours_ago(1.3), NOW, 6), "fresh")
        self.assertEqual(f.verdict(hours_ago(6), NOW, 6), "fresh")

    def test_two_missed_refreshes_is_stale(self):
        self.assertEqual(f.verdict(hours_ago(6.1), NOW, 6), "stale")
        self.assertEqual(f.verdict(hours_ago(9 * 24), NOW, 6), "stale")   # the 10/22-31 stall

    def test_no_stamp_is_never_fresh(self):
        self.assertEqual(f.verdict(None, NOW, 6), "unknown")

    def test_a_stamp_from_the_future_is_not_fresh(self):
        self.assertEqual(f.verdict(hours_ago(-2), NOW, 6), "unknown")

    def test_reads_either_spelling_from_the_head_of_the_file(self):
        self.assertEqual(f.stamp_in(b'{"generated_at":"2026-11-10T00:42:15Z","categories":['),
                         datetime.datetime(2026, 11, 10, 0, 42, 15, tzinfo=UTC))
        self.assertEqual(f.stamp_in(b'{"generatedAt": "2026-11-09T18:42:49Z"'),
                         datetime.datetime(2026, 11, 9, 18, 42, 49, tzinfo=UTC))
        self.assertIsNone(f.stamp_in(b'{"products": []}'))
        self.assertIsNone(f.stamp_in(b'{"generated_at":"yesterday"}'))

    def test_file_stamp_and_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            fresh, bare = os.path.join(d, "fresh.json"), os.path.join(d, "bare.json")
            stamp = (datetime.datetime.now(UTC) - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
            old = (datetime.datetime.now(UTC) - datetime.timedelta(hours=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
            with open(fresh, "w") as fh:
                fh.write('{"generated_at":"%s","products":[]}' % stamp)
            with open(bare, "w") as fh:
                fh.write('{"products":[]}')
            stale = os.path.join(d, "stale.json")
            with open(stale, "w") as fh:
                fh.write('{"generated_at":"%s","products":[]}' % old)
            self.assertEqual(f.main([fresh]), 0)
            self.assertEqual(f.main([stale]), 1)
            self.assertEqual(f.main([bare]), 2)
            self.assertEqual(f.main([os.path.join(d, "missing.json")]), 2)
            self.assertEqual(f.main([stale, "--max-hours", "48"]), 0)

    def test_only_https_is_fetched(self):
        self.assertIsNone(f.url_stamp("file:///etc/passwd"))
        self.assertIsNone(f.url_stamp("http://marracat.com/catalog-v3.json"))


if __name__ == "__main__":
    unittest.main()
