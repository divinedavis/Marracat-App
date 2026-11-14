"""scripts/affected_tests.py: a change always selects something to run."""
import contextlib
import io
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))
import affected_tests as a  # noqa: E402


def selection(files, argv=()):
    out = io.StringIO()
    with mock.patch.object(a, "changed_files", return_value=list(files)), \
            mock.patch.object(sys, "argv", ["affected_tests.py", *argv]), contextlib.redirect_stdout(out):
        a.main()
    return out.getvalue().split()


class NeverEmpty(unittest.TestCase):
    def test_no_changed_swift_still_runs_the_unit_tests_and_a_launch(self):
        got = selection([])
        self.assertIn(f"-only-testing:{a.UNIT}", got)
        self.assertIn(f"-only-testing:{a.SMOKE}", got)

    def test_every_argument_is_an_only_testing_flag(self):
        # scripts/test_affected.sh refuses anything else as "no tests selected".
        got = selection([])
        self.assertTrue(got and all(t.startswith("-only-testing:") for t in got), got)

    def test_the_list_form_is_never_empty_either(self):
        self.assertTrue(selection([], ["--list"]))


if __name__ == "__main__":
    unittest.main()
