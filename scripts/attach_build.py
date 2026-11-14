#!/usr/bin/env python3
"""Attach a processed build to the App Store version in App Store Connect.

Why: the icon in App Store Connect's header (and on the listing) comes from
the build attached to the App Store version, not from TestFlight uploads.
Until one is attached, ASC shows the grey placeholder grid.

The build's marketing version must match the App Store version string
(a 0.1.0 build can't attach to version 1.0). Pass --build N to pick an exact
build: a fresh upload takes minutes to surface, so "newest VALID" can
otherwise grab an older build.

Usage:
    ~/.venvs/marracat/bin/python scripts/attach_build.py --build 8
    ~/.venvs/marracat/bin/python scripts/attach_build.py --dry-run
"""
from __future__ import annotations

import argparse

from asc import api, load_config, make_token

# States in which the version's build can still be swapped.
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
            "METADATA_REJECTED", "INVALID_BINARY", "WAITING_FOR_REVIEW"}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", help="exact build number (CFBundleVersion) to attach")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cfg = load_config()
    app_id = cfg.get("ASC_APP_ID") or exit("ASC_APP_ID is empty — run scripts/register_in_asc.py")
    token = make_token(cfg)

    _, res = api(token, "GET", f"/apps/{app_id}/appStoreVersions",
                 params={"limit": 5, "fields[appStoreVersions]": "versionString,appStoreState"})
    versions = res.get("data", [])
    if not versions:
        raise SystemExit("no App Store version on this app")
    version = versions[0]
    vstring, state = version["attributes"]["versionString"], version["attributes"]["appStoreState"]
    print(f"==> App Store version {vstring} ({state})")

    _, cur = api(token, "GET", f"/appStoreVersions/{version['id']}/build")
    current = cur.get("data")

    params = {"filter[app]": app_id, "filter[preReleaseVersion.version]": vstring,
              "filter[processingState]": "VALID", "sort": "-uploadedDate", "limit": 20,
              "fields[builds]": "version,processingState,expired,uploadedDate"}
    if args.build:
        params["filter[version]"] = args.build
    _, res = api(token, "GET", "/builds", params=params)
    builds = [b for b in res.get("data", []) if not b["attributes"].get("expired")]
    if not builds:
        raise SystemExit(f"no VALID {vstring} build{' ' + args.build if args.build else ''} yet — "
                         "still processing, or its marketing version doesn't match")
    pick = builds[0]
    number = pick["attributes"]["version"]
    print(f"==> build {vstring} ({number})")

    if current and current["id"] == pick["id"]:
        print("    already attached")
        return
    if state not in EDITABLE:
        raise SystemExit(f"version is {state}; its build can't be changed")
    if args.dry_run:
        print("    would attach (dry run)")
        return
    api(token, "PATCH", f"/appStoreVersions/{version['id']}/relationships/build",
        body={"data": {"type": "builds", "id": pick["id"]}})
    print(f"    attached build {number} to version {vstring} — the ASC icon updates within a few minutes")


if __name__ == "__main__":
    main()
