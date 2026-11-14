"""scripts/decision_bakeoff.py: the scoring maths, no network."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import decision_bakeoff as db  # noqa: E402


def row(truth, answer, ms=100, cost=0.0001):
    return {"ok": True, "truth": truth, "answer": answer, "ms": ms, "cost": cost, "tokens": 100}


class BakeoffScoring(unittest.TestCase):
    def test_predicate_accuracy_brier_and_decision_score(self):
        rows = [row(True, {"probability": 0.9}), row(False, {"probability": 0.2}),
                row(True, {"probability": 0.4}), {"ok": False, "truth": True, "error": "HTTP 500"}]
        s = db.score("is_a", rows)
        self.assertEqual((s["answered"], s["failed"]), (3, 1))
        self.assertAlmostEqual(s["accuracy"], 2 / 3)
        self.assertAlmostEqual(s["brier"], (0.01 + 0.04 + 0.36) / 3)
        self.assertAlmostEqual(s["decision_score"], 50 * (1 + 2 / 3 - s["brier"]))

    def test_choice_uses_the_probability_spread(self):
        sure = row("hair", {"choice": "hair", "probabilities": [{"value": "hair", "probability": 1.0}]})
        split = row("hair", {"choice": "skincare", "probabilities": [{"value": "hair", "probability": 0.4},
                                                                   {"value": "skincare", "probability": 0.6}]})
        s = db.score("department", [sure, split])
        self.assertAlmostEqual(s["accuracy"], 0.5)
        self.assertAlmostEqual(s["brier"], (0.0 + (0.36 + 0.36) / 2) / 2)

    def test_a_choice_without_probabilities_counts_as_certain(self):
        s = db.score("department", [row("hair", {"choice": "hair"})])
        self.assertEqual((s["accuracy"], s["brier"]), (1.0, 0.0))


if __name__ == "__main__":
    unittest.main()
