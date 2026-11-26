"""scripts/daily_ship.sh: what it counts as not built yet.

2026-11-26: a by-hand ship made build 201 while the 03:00 run waited for the
build lock. The 03:00 run had listed its changes before the wait, so it tested
the same code again and nearly uploaded it a second time as 202.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("daily_ship.sh").read_text()


def git_env():
    # Under a git hook GIT_DIR and friends point at the real repository.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
    return env


class UnbuiltChanges(unittest.TestCase):
    def setUp(self):
        self.function = re.search(r"^unbuilt_changes\(\) \{\n.*?^\}\n", SCRIPT, re.S | re.M).group(0)
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.bump(200)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repo, env=git_env(), check=True, capture_output=True)

    def bump(self, build):
        (self.repo / "project.yml").write_text(f'    CURRENT_PROJECT_VERSION: "{build}"\n')
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"Bump to 1.15 ({build}): daily build")

    def app_commit(self, subject):
        app = self.repo / "Marracat"
        app.mkdir(exist_ok=True)
        (app / "View.swift").write_text(subject)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", subject)

    def changes(self):
        run = subprocess.run(["bash", "-c", f'APP_PATHS=(Marracat)\n{self.function}\nunbuilt_changes; printf %s "$changes"'],
                             cwd=self.repo, env=git_env(), check=True, capture_output=True, text=True)
        return run.stdout

    def test_an_app_commit_after_the_last_build_is_waiting(self):
        self.app_commit("Put a picture on the empty cart")
        self.assertEqual(self.changes(), "- Put a picture on the empty cart")

    def test_nothing_is_waiting_once_another_ship_has_built_it(self):
        self.app_commit("Put a picture on the empty cart")
        self.bump(201)
        self.assertEqual(self.changes(), "")


class LooksAgainAfterTheWait(unittest.TestCase):
    def test_the_list_is_made_again_once_the_lock_is_held(self):
        lock = SCRIPT.index('build_lock_try "Marracat daily_ship.sh"')
        ship = SCRIPT.index('say "test tier: $tier"')
        after = SCRIPT[lock:ship]
        self.assertRegex(after, r"git pull --ff-only[^\n]*\nunbuilt_changes\n", "no second look after the wait for the lock")
        self.assertIn("nothing to ship\"; exit 0", after)


if __name__ == "__main__":
    unittest.main()
