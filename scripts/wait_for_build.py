#!/usr/bin/env python3
"""Wait until an uploaded build is processed and available to internal testers.

Polls App Store Connect once a minute; dropped connections are retried
(ASC resets TLS handshakes now and then). Exits 0 when the build is VALID
and IN_BETA_TESTING, 1 if Apple marks it INVALID/FAILED or on timeout — so
it can gate `attach_build.py` in a shell chain.

Usage:
    ~/.venvs/marracat/bin/python scripts/wait_for_build.py 12
    ~/.venvs/marracat/bin/python scripts/wait_for_build.py 12 --timeout 3600
"""
from __future__ import annotations

import argparse
import sys
import time

import requests

from asc import api, load_config, make_token


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("build", help="build number (CFBundleVersion)")
    ap.add_argument("--timeout", type=int, default=2400, help="seconds (default 40 min)")
    args = ap.parse_args()

    cfg = load_config()
    deadline = time.time() + args.timeout
    last = None
    while time.time() < deadline:
        try:
            _, r = api(make_token(cfg), "GET", "/builds", params={
                "filter[app]": cfg["ASC_APP_ID"], "filter[version]": args.build, "limit": 1,
                "include": "buildBetaDetail", "fields[builds]": "version,processingState"})
        except requests.exceptions.RequestException as e:
            print(time.strftime("%H:%M:%S"), "network error, retrying:", type(e).__name__, flush=True)
            time.sleep(20)
            continue
        data = r.get("data", [])
        state = data[0]["attributes"]["processingState"] if data else "NOT_LISTED_YET"
        beta = next((i["attributes"].get("internalBuildState")
                     for i in r.get("included", []) if i["type"] == "buildBetaDetails"), None)
        line = f"{state} / internal={beta}"
        if line != last:
            print(time.strftime("%H:%M:%S"), f"build {args.build}:", line, flush=True)
            last = line
        if state in ("INVALID", "FAILED"):
            return 1
        if state == "VALID" and beta == "IN_BETA_TESTING":
            return 0
        time.sleep(60)
    print("timed out; last:", last)
    return 1


if __name__ == "__main__":
    sys.exit(main())
