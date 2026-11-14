#!/usr/bin/env python
"""Moves MARKETING_VERSION in project.yml to the next version once Apple has
approved the current one (scripts/ship.sh runs this before every ship).

An approved version is a closed train: an upload to it fails with ITMS-90186
("the train version is closed"), which cost a ship on 2026-10-21 when 1.7
went live mid-round. So: when the App Store version matching project.yml is
approved, released or replaced, 1.8 becomes 1.9 (1.9 becomes 1.10). A version
waiting for or in review still takes builds and is left alone, as is one that
isn't in App Store Connect yet.

    ~/.venvs/marracat/bin/python scripts/next_version.py [--dry-run]
"""
from __future__ import annotations

import pathlib
import re
import sys

import asc

PROJECT = pathlib.Path(__file__).resolve().parent.parent / "project.yml"
CLOSED = {"PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE",
          "READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION",
          "DEVELOPER_REMOVED_FROM_SALE", "REMOVED_FROM_SALE"}
LINE = re.compile(r'(MARKETING_VERSION: ")(\d+)\.(\d+)(")')


def bumped(version: str) -> str:
    major, minor = version.split(".")[:2]
    return f"{major}.{int(minor) + 1}"


def main() -> int:
    text = PROJECT.read_text()
    m = LINE.search(text)
    if not m:
        print("next_version: no MARKETING_VERSION in project.yml", file=sys.stderr)
        return 1
    current = f"{m.group(2)}.{m.group(3)}"
    cfg = asc.load_config()
    token = asc.make_token(cfg)
    s, d = asc.api(token, "GET", f"/apps/{cfg['ASC_APP_ID']}/appStoreVersions",
                   params={"limit": 10, "filter[platform]": "IOS",
                           "fields[appStoreVersions]": "versionString,appStoreState"})
    if s != 200:
        print(f"next_version: App Store Connect said {s}; keeping {current}", file=sys.stderr)
        return 0
    states = {v["attributes"]["versionString"]: v["attributes"].get("appStoreState") for v in d.get("data", [])}
    state = states.get(current)
    if state not in CLOSED:
        print(f"version {current} ({state or 'not in App Store Connect yet'}): keeping it")
        return 0
    nxt = bumped(current)
    print(f"version {current} is {state}, a closed train: moving to {nxt}")
    if "--dry-run" not in sys.argv:
        PROJECT.write_text(LINE.sub(lambda x: f'{x.group(1)}{nxt}{x.group(4)}', text, count=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
