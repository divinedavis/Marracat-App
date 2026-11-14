import json
import os
import sqlite3
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "web", "metrics"))
import marracat_metrics as m  # noqa: E402


class AppPerformance(unittest.TestCase):
    """MetricKit reports summarised per build for the owner dashboard."""

    def test_launch_hang_memory_and_diagnostics_by_build(self):
        db = sqlite3.connect(":memory:")
        db.execute("CREATE TABLE app_metrics (id INTEGER PRIMARY KEY, device TEXT, kind TEXT, build TEXT, received INTEGER, report TEXT)")
        metric = {"applicationLaunchMetrics": {"histogrammedTimeToFirstDraw": {"histogramNumBuckets": 2, "histogramValue": {
            "0": {"bucketStart": "1,000 ms", "bucketEnd": "1,010 ms", "bucketCount": 3},
            "1": {"bucketStart": "2,000 ms", "bucketEnd": "2,010 ms", "bucketCount": 1}}}},
            "applicationResponsivenessMetrics": {"histogrammedAppHangTime": {"histogramValue": {"0": {"bucketStart": "0 ms", "bucketEnd": "100 ms", "bucketCount": 5}}}},
            "memoryMetrics": {"peakMemoryUsage": "212,992 kB"}}
        db.execute("INSERT INTO app_metrics VALUES (1,'d1','metric','94',0,?)", (json.dumps(metric),))
        db.execute("INSERT INTO app_metrics VALUES (2,'d1','diagnostic','94',0,?)", (json.dumps({"crashDiagnostics": [{}], "hangDiagnostics": [{}, {}]}),))
        db.execute("INSERT INTO app_metrics VALUES (3,'d2','metric','93',0,'{}')")
        out = m.app_performance(db)
        self.assertTrue(out[0]["build"] == "94" and out[0]["launch_ms"] == 1005 and out[0]["launches"] == 4)
        self.assertTrue(out[0]["hang_ms"] == 50 and out[0]["peak_memory_mb"] == 208 and out[0]["crashes"] == 1 and out[0]["hangs"] == 2)
        self.assertTrue(out[1]["build"] == "93" and out[1]["launch_ms"] is None)

    def test_no_table_means_no_rows(self):
        self.assertEqual(m.app_performance(sqlite3.connect(":memory:")), [])


if __name__ == "__main__":
    unittest.main()
