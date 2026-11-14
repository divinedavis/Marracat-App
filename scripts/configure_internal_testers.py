#!/usr/bin/env python3
"""Ensure Marracat has an internal TestFlight group with automatic build
distribution, and that ASC_TESTER_EMAIL is in it.

Internal builds skip Beta App Review, but only reach testers without a manual
click when the group has hasAccessToAllBuilds on. Idempotent — ship.sh runs it
after every upload.

Usage:
    ~/.venvs/marracat/bin/python scripts/configure_internal_testers.py
"""
from __future__ import annotations

from asc import api, load_config, make_token

GROUP_NAME = "Internal Testers"


def main() -> None:
    cfg = load_config()
    app_id = cfg.get("ASC_APP_ID")
    if not app_id:
        raise SystemExit("ASC_APP_ID missing — run scripts/register_in_asc.py first")
    email = cfg.get("ASC_TESTER_EMAIL", "")
    token = make_token(cfg)

    _, res = api(token, "GET", f"/apps/{app_id}/betaGroups", params={"limit": 200})
    groups = [g for g in res.get("data", []) if g["attributes"].get("isInternalGroup")]
    if groups:
        group = groups[0]
        print(f"   internal group '{group['attributes']['name']}' ({group['id']})")
        if not group["attributes"].get("hasAccessToAllBuilds"):
            api(token, "PATCH", f"/betaGroups/{group['id']}", body={"data": {
                "id": group["id"], "type": "betaGroups", "attributes": {"hasAccessToAllBuilds": True}}})
            print("   turned on automatic build distribution")
    else:
        _, res = api(token, "POST", "/betaGroups", body={"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})
        group = res["data"]
        print(f"   created internal group '{GROUP_NAME}' ({group['id']}) with automatic distribution")

    if not email:
        print("   ASC_TESTER_EMAIL unset — no tester added")
        return

    _, res = api(token, "GET", f"/betaGroups/{group['id']}/betaTesters", params={"limit": 200})
    if any(t["attributes"].get("email", "").lower() == email.lower() for t in res.get("data", [])):
        print(f"   {email} is already in the group")
        return

    # Internal testers must already be ASC users on the team; Apple matches by email.
    status, res = api(token, "POST", "/betaTesters", ok_statuses=(409, 422), body={"data": {
        "type": "betaTesters",
        "attributes": {"email": email},
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group["id"]}]}},
    }})
    if status < 400:
        print(f"   added {email} to the group")
    else:
        detail = " ".join(e.get("detail", "") for e in res.get("errors", []))
        print(f"   could not add {email} ({status}): {detail}")


if __name__ == "__main__":
    main()
