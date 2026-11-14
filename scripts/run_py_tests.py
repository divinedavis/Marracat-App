#!/usr/bin/env python3
"""Run every Python test in the repo: catalog/test_*.py and scripts/test_*.py.

    python3 scripts/run_py_tests.py      # exit 0 only if every test passes

Loads unittest TestCase classes AND bare pytest-style `def test_*()` functions
(there is no pytest here; `unittest discover` silently runs zero of the bare
kind). Each test file's own directory goes on sys.path, the way the catalog
tests import their sibling modules. Called by scripts/run_tests.sh.
"""
from __future__ import annotations

import importlib.util
import inspect
import sys
import traceback
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIRS = ("catalog", "scripts")


def main() -> int:
    suite = unittest.TestSuite()
    bare = []
    files = sorted(p for d in DIRS for p in (ROOT / d).glob("test_*.py"))
    for path in files:
        sys.path.insert(0, str(path.parent))
        spec = importlib.util.spec_from_file_location(f"{path.parent.name}_{path.stem}", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(mod))
        for name, fn in vars(mod).items():
            if name.startswith("test_") and inspect.isfunction(fn) and fn.__module__ == mod.__name__:
                bare.append((f"{path.stem}.{name}", fn))
    result = unittest.TextTestRunner(verbosity=0, stream=sys.stderr).run(suite)
    failed = len(result.failures) + len(result.errors)
    for label, fn in bare:
        try:
            fn()
        except Exception:
            failed += 1
            print(f"FAIL {label}\n{traceback.format_exc()}", file=sys.stderr)
    total = result.testsRun + len(bare)
    print(f"python tests: {total - failed}/{total} passed ({len(files)} files)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
