#!/usr/bin/env python
"""Validate — and only with --submit, send — the App Store version for review.

    ~/.venvs/marracat/bin/python scripts/submit_for_review.py            # validate
    ~/.venvs/marracat/bin/python scripts/submit_for_review.py --submit   # send to Apple

Attaching the version to the review submission is what runs Apple's readiness
validation: a 409 lists every unmet requirement in `associatedErrors`, and the
item is not created. Attaching is reversible (the item can be deleted); actually
submitting is not, so it needs the explicit flag.
"""
from __future__ import annotations

import argparse
import json
import sys

import asc


def find(token: str, app_id: str) -> tuple[dict, dict]:
    s, d = asc.api(token, "GET", f"/apps/{app_id}/appStoreVersions", params={"limit": 10})
    if s != 200:
        raise SystemExit(f"cannot list versions: {json.dumps(d)}")
    # READY_FOR_REVIEW is the state a version enters once it is attached to a
    # draft submission — still not sent to Apple, so it stays actionable here.
    actionable = {"PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED",
                  "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
    version = next((v for v in d["data"] if (v["attributes"].get("appStoreState") or v["attributes"].get("appVersionState")) in actionable), None)
    if version is None:
        raise SystemExit("no editable App Store version — nothing to submit")

    s, d = asc.api(token, "GET", f"/apps/{app_id}/reviewSubmissions", params={"limit": 10})
    if s != 200:
        raise SystemExit(f"cannot list review submissions: {json.dumps(d)}")
    draft = next((r for r in d["data"] if r["attributes"].get("state") == "READY_FOR_REVIEW"), None)
    if draft is None:
        s, d = asc.api(token, "POST", "/reviewSubmissions", body={"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        if s not in (200, 201):
            raise SystemExit(f"cannot create a review submission: {json.dumps(d)}")
        draft = d["data"]
    return version, draft


def ensure_no_phased_release(token: str, version: dict) -> None:
    """Release to everyone at once (owner, 2026-10-13: "we dont need 7 day
    gradual rollout - one big bang"), so a phased release left on the version
    from the dashboard or an earlier run is removed before submitting."""
    s, d = asc.api(token, "GET", f"/appStoreVersions/{version['id']}/appStoreVersionPhasedRelease",
                   ok_statuses=(404,))
    if s == 200 and d.get("data"):
        asc.api(token, "DELETE", f"/appStoreVersionPhasedReleases/{d['data']['id']}")
        print("phased release: removed (releases to everyone at once)")
    else:
        print("phased release: off (releases to everyone at once)")


def report(payload: dict) -> None:
    for err in payload.get("errors", []):
        print(f"  {err.get('code')}: {err.get('title')}")
        for path, items in (err.get("meta", {}).get("associatedErrors") or {}).items():
            for item in items:
                print(f"    [{path}] {item.get('code')}: {item.get('title')} — {item.get('detail')}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--submit", action="store_true", help="send the submission to Apple after it validates")
    args = parser.parse_args()

    cfg = asc.load_config()
    token = asc.make_token(cfg)
    app_id = cfg["ASC_APP_ID"]
    version, draft = find(token, app_id)
    state = version["attributes"].get("appStoreState") or version["attributes"].get("appVersionState")
    print(f"version {version['attributes'].get('versionString')} ({state}) → submission {draft['id']}")

    # The items listing omits relationship linkage unless it is included.
    s, d = asc.api(token, "GET", f"/reviewSubmissions/{draft['id']}/items",
                   params={"include": "appStoreVersion"})
    attached = any(i["id"] == version["id"] for i in d.get("included", []) if i["type"] == "appStoreVersions")

    if not attached:
        s, d = asc.api(token, "POST", "/reviewSubmissionItems", ok_statuses=(400, 409, 422), body={"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": draft["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
        already = any(e.get("code") == "ENTITY_ERROR.RELATIONSHIP.INVALID.NOT_ALLOWED"
                      for e in d.get("errors", []))
        if s not in (200, 201) and not already:
            print("NOT READY — Apple rejected the version:")
            report(d)
            return 1
        print("already attached" if already else "attached; Apple's validation passed")
    else:
        print("already attached; Apple's validation passed")

    if not args.submit:
        print("validation only — re-run with --submit to send it to Apple")
        return 0

    # Only on the real submit, so a validation run never writes to the version.
    ensure_no_phased_release(token, version)
    s, d = asc.api(token, "PATCH", f"/reviewSubmissions/{draft['id']}", ok_statuses=(400, 409, 422), body={"data": {
        "type": "reviewSubmissions", "id": draft["id"], "attributes": {"submitted": True}}})
    if s != 200:
        print("submission refused:")
        report(d)
        return 1
    print(f"submitted — state {d['data']['attributes'].get('state')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
