"""scripts/perf_gate.py's judgement of one metric against its baseline."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import perf_gate as g  # noqa: E402


def metric(median, unit, smaller=True):
    return {"median": median, "unit": unit, "smaller": smaller}


class PerfGate(unittest.TestCase):
    def test_relative_tolerance(self):
        self.assertFalse(g.regressed(metric(1.4, "s"), 1.0))
        self.assertTrue(g.regressed(metric(1.6, "s"), 1.0))

    def test_home_fling_stall_needs_three_frames_more(self):
        # A ~190 ms baseline stall (XCUITest's own snapshots) wobbling to 300 ms
        # is still noise; the 760 ms freeze build 132 had is not.
        self.assertFalse(g.regressed(metric(30, "ms"), 10))
        self.assertTrue(g.regressed(metric(300, "ms"), 190))
        self.assertTrue(g.regressed(metric(760, "ms"), 190))

    def test_hitch_ratio_floor(self):
        self.assertFalse(g.regressed(metric(12, "ms/s"), 4))
        self.assertTrue(g.regressed(metric(140, "ms/s"), 85))

    def test_memory_floor_still_holds(self):
        self.assertFalse(g.regressed(metric(852, "kB"), 344))
        self.assertTrue(g.regressed(metric(900000, "kB"), 500000))


class FixedCeiling(unittest.TestCase):
    """scripts/perf_ceilings.json: a bar the rolling baseline can't drift past."""

    def test_over_the_ceiling_fails_even_when_the_rolling_baseline_passes(self):
        creeping = metric(2150, "ms")
        self.assertFalse(g.regressed(creeping, 2017))       # 6.6% over the last five: fine by the rolling rule
        self.assertTrue(g.over_ceiling(creeping, 2100.0))

    def test_at_or_under_the_ceiling_passes(self):
        self.assertFalse(g.over_ceiling(metric(2100, "ms"), 2100.0))
        self.assertFalse(g.over_ceiling(metric(2017, "ms"), 2100.0))

    def test_no_ceiling_and_prefers_larger_are_left_alone(self):
        self.assertFalse(g.over_ceiling(metric(9999, "ms"), None))
        self.assertFalse(g.over_ceiling(metric(9999, "fps", smaller=False), 100.0))

    def test_the_shipped_ceilings_file_loads_and_covers_launch(self):
        ceilings = g.load_ceilings()
        key = "PerformanceTests/testHomeFlingAfterLaunch() :: Launch to interactive Home"
        self.assertEqual(ceilings[key], 2100.0)
        # Every ceiling must name a metric the baseline knows, or it guards nothing.
        import json
        baseline = json.load(open(g.BASELINE))
        self.assertTrue(set(ceilings) <= set(baseline), set(ceilings) - set(baseline))

    def test_a_missing_file_means_no_ceilings(self):
        self.assertEqual(g.load_ceilings("/nonexistent/perf_ceilings.json"), {})


if __name__ == "__main__":
    unittest.main()
