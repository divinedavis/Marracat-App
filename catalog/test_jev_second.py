"""Decider as Jev's second opinion (owner, 2026-11-12): what counts as sure."""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import build_catalog as bc  # noqa: E402
import jev_categories as jc  # noqa: E402


def verdict(conf, choice="books", second=None, seen="k"):
    v = {"seen": seen, "choice": choice, "confidence": conf, "p": 0.5, "was": "music"}
    if second:
        v["second"] = {"model": jc.SECOND_MODEL, "seen": seen, **second}
    return v


class JevConfident(unittest.TestCase):
    def test_jev_alone_still_needs_085(self):
        self.assertTrue(bc.jev_confident(verdict(0.85)))
        self.assertFalse(bc.jev_confident(verdict(0.84)))
        self.assertFalse(bc.jev_confident(None))

    def test_decider_agreeing_settles_an_unsure_verdict(self):
        self.assertTrue(bc.jev_confident(verdict(0.70, second={"choice": "books", "p": 0.5})))

    def test_decider_disagreeing_or_unsure_does_not(self):
        self.assertFalse(bc.jev_confident(verdict(0.70, second={"choice": "music", "p": 0.99})))
        self.assertFalse(bc.jev_confident(verdict(0.70, second={"choice": "books", "p": 0.49})))

    def test_below_the_floor_decider_cannot_rescue_it(self):
        self.assertFalse(bc.jev_confident(verdict(0.59, second={"choice": "books", "p": 0.99})))

    def test_a_second_opinion_about_older_text_does_not_count(self):
        v = verdict(0.70, second={"choice": "books", "p": 0.9})
        v["second"]["seen"] = "old"
        self.assertFalse(bc.jev_confident(v))


class NeedsSecond(unittest.TestCase):
    def setUp(self):
        self._key = jc.input_key
        jc.input_key = lambda p: "k"

    def tearDown(self):
        jc.input_key = self._key

    def test_only_unsure_moves_without_an_answer_are_asked(self):
        p = {"id": "x", "category": "music"}
        self.assertTrue(jc.needs_second(verdict(0.7), p))
        self.assertFalse(jc.needs_second(verdict(0.9), p))                    # Jev is sure alone
        self.assertFalse(jc.needs_second(verdict(0.5), p))                    # below the floor
        self.assertFalse(jc.needs_second(verdict(0.7, choice="music"), p))    # not a move
        self.assertFalse(jc.needs_second(verdict(0.7, seen="old"), p))        # Jev read older text
        self.assertFalse(jc.needs_second(verdict(0.7, second={"choice": "books", "p": 0.1}), p))  # asked already


if __name__ == "__main__":
    unittest.main()
