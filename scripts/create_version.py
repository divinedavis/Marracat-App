#!/usr/bin/env python
"""Open the next App Store version, carrying the live version's metadata over.

    ~/.venvs/marracat/bin/python scripts/create_version.py --version 1.1 \
        --whats-new "What changed in this release."

Version 1.0 is READY_FOR_SALE and cannot take a new build: an approved version
is finished. A new build reaches the public only under a new version, whose
`versionString` must match the binary's CFBundleShortVersionString — so bump
MARKETING_VERSION in project.yml and ship before running this.

Apple does not copy a released version's description, keywords or screenshots
to a new one through the API, so this reads the previous localization and
writes it onto the new version. Screenshots are attached to the old version's
sets and are not copied; a version that changes them needs
upload_app_store_screenshots.py.

Creating a version is reversible (it sits in PREPARE_FOR_SUBMISSION until
something submits it), so this runs without a confirmation flag. Sending it to
Apple is submit_for_review.py --submit.
"""
from __future__ import annotations

import argparse
import json

import asc
from release_notes import as_paragraphs

COPIED = ("description", "keywords", "marketingUrl", "promotionalText",
          "supportUrl")


def latest_version(token: str, app_id: str) -> dict:
    s, d = asc.api(token, "GET", f"/apps/{app_id}/appStoreVersions",
                   params={"limit": 5, "fields[appStoreVersions]": "versionString,appStoreState,platform"})
    if s != 200 or not d.get("data"):
        raise SystemExit(f"cannot list versions: {json.dumps(d)}")
    return d["data"][0]


def localizations(token: str, version_id: str) -> list[dict]:
    s, d = asc.api(token, "GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations",
                   params={"limit": 50})
    if s != 200:
        raise SystemExit(f"cannot read localizations: {json.dumps(d)}")
    return d["data"]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True, help='e.g. 1.1 — must match MARKETING_VERSION')
    ap.add_argument("--whats-new", required=True, help="release notes shown on the update")
    ap.add_argument("--app", default="6810905687")
    args = ap.parse_args()

    cfg = asc.load_config()
    token = asc.make_token(cfg)
    previous = latest_version(token, args.app)
    prev_attrs = previous["attributes"]
    print(f"==> previous version {prev_attrs['versionString']} ({prev_attrs.get('appStoreState')})")
    if prev_attrs["versionString"] == args.version:
        raise SystemExit(f"version {args.version} already exists ({prev_attrs.get('appStoreState')})")

    s, created = asc.api(token, "POST", "/appStoreVersions", body={"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": prev_attrs.get("platform", "IOS"),
                       "versionString": args.version,
                       "releaseType": "AFTER_APPROVAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": args.app}}},
    }}, ok_statuses=(409,))
    if s == 409:
        raise SystemExit(f"App Store refused the version: {json.dumps(created)}")
    version_id = created["data"]["id"]
    print(f"==> created version {args.version} ({version_id})")

    # Carry the live version's text across, then write the release notes.
    previous_text = {loc["attributes"]["locale"]: loc["attributes"] for loc in localizations(token, previous["id"])}
    for loc in localizations(token, version_id):
        locale = loc["attributes"]["locale"]
        source = previous_text.get(locale)
        attrs = {"whatsNew": as_paragraphs(args.whats_new)}
        if source:
            attrs.update({k: source.get(k) for k in COPIED if source.get(k)})
        s, res = asc.api(token, "PATCH", f"/appStoreVersionLocalizations/{loc['id']}", body={"data": {
            "type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": attrs}})
        carried = "carried over" if source else "left as Apple created it"
        print(f"   {locale}: release notes set, description {carried}")
    print("==> next: attach_build.py --build N, then submit_for_review.py --submit")


if __name__ == "__main__":
    main()
