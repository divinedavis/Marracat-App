#!/usr/bin/env python3
"""The tests a change touches, as xcodebuild -only-testing arguments, for
iterating without the full ~24-minute suite (owner, 2026-10-21). The full
suite still runs on every ship (scripts/daily_ship.sh, scripts/ship.sh).

A changed app file reaches a test through:
  - the types it declares (struct/class/enum/actor/protocol/extension names),
    looked up in unit test files -> the whole test class or suite;
  - the accessibility identifiers it sets, looked up in UI test methods ->
    just those methods (the big UI classes run a third of the suite each);
  - a changed test file -> its own classes (UI: its changed methods' classes).
Nothing reached -> the unit tests only, plus a launch smoke UI test.

    python3 scripts/affected_tests.py [--base origin/main] [--list]
"""
import argparse
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_DIRS = ("Marracat/", "MarracatWidgets/")
UNIT, UI = "MarracatTests", "MarracatUITests"
SMOKE = f"{UI}/MarracatUITests3/testColdLaunchShowsSplash"
DECL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|final|nonisolated)\s+)*"
                  r"(?:struct|class|enum|actor|protocol|extension)\s+([A-Z][A-Za-z0-9_]*)", re.M)
IDENT = re.compile(r'accessibilityIdentifier\(\s*"([^"\\]+)')
# Test classes: XCTestCase's, or a shared base's (MarracatUITestCase) subclasses.
CLASS = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:XCTestCase|\w+UITestCase)\b", re.M)
BASES = {"MarracatUITestCase"}
SUITE = re.compile(r"^\s*(?:@Suite[^\n]*\n\s*)?(?:@MainActor\s+)?(?:final\s+)?(?:struct|class)\s+(\w+Tests)\b", re.M)
METHOD = re.compile(r"^\s*(?:@MainActor\s+)?func\s+(test\w*)\s*\(", re.M)


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout


def changed_files(base):
    files = set(git("diff", "--name-only", f"{base}...HEAD").split())
    files |= set(git("diff", "--name-only", "HEAD").split())
    files |= set(git("ls-files", "--others", "--exclude-standard").split())
    return sorted(f for f in files if f.endswith(".swift") and (ROOT / f).exists())


def unit_targets(names):
    out = set()
    for f in (ROOT / UNIT).rglob("*.swift"):
        text = f.read_text(errors="ignore")
        if any(re.search(rf"\b{re.escape(n)}\b", text) for n in names):
            out |= {f"{UNIT}/{c}" for c in CLASS.findall(text) + SUITE.findall(text) if c not in BASES}
    return out


def changed_lines(rel, base):
    """New-file line numbers a diff touches (this branch + uncommitted)."""
    out = set()
    for diff in (git("diff", "-U0", f"{base}...HEAD", "--", rel), git("diff", "-U0", "HEAD", "--", rel)):
        for m in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", diff, re.M):
            start, n = int(m.group(1)), int(m.group(2) or 1)
            out |= set(range(start, start + max(n, 1)))
    return out


def ui_methods(text):
    """(class, method, body, first line, last line) per UI test method."""
    classes = [(m.start(), m.group(1)) for m in CLASS.finditer(text)]
    starts = [(m.start(), m.group(1)) for m in METHOD.finditer(text)]
    for i, (at, name) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        owner = [c for pos, c in classes if pos < at]
        if owner and owner[-1] not in BASES:
            yield owner[-1], name, text[at:end], text.count("\n", 0, at) + 1, text.count("\n", 0, end) + 1


HELPER = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:static|private|fileprivate)\s+)*func\s+([a-z]\w*)\s*\(", re.M)


def ui_targets(idents, changed_ui_files, base):
    """UI test methods that use a changed identifier, were edited, or call a
    helper (Waiting.swift, the base class) that was edited."""
    helpers, edited = set(), {}
    for rel in changed_ui_files:
        text = (ROOT / rel).read_text(errors="ignore")
        lines = changed_lines(rel, base)
        edited[rel] = lines
        rows = text.split("\n")
        funcs = [(text.count("\n", 0, m.start()) + 1, m.group(1)) for m in HELPER.finditer(text)]
        for i, (line, name) in enumerate(funcs):
            stop = funcs[i + 1][0] if i + 1 < len(funcs) else len(rows) + 1
            # The next function's doc comment and attributes aren't this one's.
            while stop - 2 > line and stop - 2 < len(rows) and re.match(r"\s*(///|//|@|$)", rows[stop - 2]):
                stop -= 1
            if not name.startswith("test") and lines & set(range(line, stop)):
                helpers.add(name)
    out = set()
    for f in (ROOT / UI).rglob("*.swift"):
        text = f.read_text(errors="ignore")
        rel = str(f.relative_to(ROOT))
        for cls, name, body, first, last in ui_methods(text):
            if cls == "PerformanceTests":
                continue
            hit = any(f'"{i}"' in body for i in idents)
            hit = hit or bool(edited.get(rel, set()) & set(range(first, last)))
            hit = hit or any(re.search(rf"\b{h}\(", body) for h in helpers)
            if hit:
                out.add(f"{UI}/{cls}/{name}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--list", action="store_true", help="print the targets, one a line")
    args = ap.parse_args()
    files = changed_files(args.base)
    names, idents = set(), set()
    for f in files:
        text = (ROOT / f).read_text(errors="ignore")
        if f.startswith(APP_DIRS):
            names |= set(DECL.findall(text))
            idents |= set(IDENT.findall(text))
    targets = unit_targets(names) if names else set()
    for f in files:
        if f.startswith(UNIT + "/"):
            text = (ROOT / f).read_text(errors="ignore")
            targets |= {f"{UNIT}/{c}" for c in CLASS.findall(text) + SUITE.findall(text)}
    targets |= ui_targets(idents, {f for f in files if f.startswith(UI + "/")}, args.base)
    if not any(t.startswith(UNIT) for t in targets):
        targets.add(UNIT)
    if not any(t.startswith(UI) for t in targets):
        targets.add(SMOKE)
    if args.list:
        print("\n".join(sorted(targets)))
    else:
        print(" ".join(f"-only-testing:{t}" for t in sorted(targets)))


if __name__ == "__main__":
    main()
