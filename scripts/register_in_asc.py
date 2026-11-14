#!/usr/bin/env python3
"""Register the Marracat bundle ID and capture the App Store Connect app id.

Idempotent — re-run safely. The ASC API cannot create app records (/apps is
GET + UPDATE only), so the first run registers the bundle ID, then prints the
exact values to type into App Store Connect → + → New App. Re-run afterwards
to save ASC_APP_ID into scripts/asc-config.env.

Usage:
    ~/.venvs/marracat/bin/python scripts/register_in_asc.py
"""
from __future__ import annotations

from asc import api, load_config, make_token, write_config_value

APP_NAME = "Marracat"
SKU = "marracat-001"
# The Home Screen widgets read small snapshots the app writes into this App
# Group (Shared/WidgetSnapshot.swift). The ASC API turns the capability on for
# each App ID. The API has no App Group resource, and Xcode signing with an
# API key can't register one ("Authentication failed" on archive, 2026-10-14),
# so the group was created and assigned once with an Apple ID session:
#   fastlane produce group -u <apple id> -b CG89RY4W6R -g group.com.divinedavis.marracat -n Marracat
#   fastlane produce associate_group -u <apple id> -b CG89RY4W6R -a <bundle id> group.com.divinedavis.marracat
# (group 5AN9XSC6BB, both bundle ids). A new App ID in the group needs the
# second command again.
APP_GROUP_BUNDLES = [("com.divinedavis.marracat", "Marracat"),
                     ("com.divinedavis.marracat.widgets", "Marracat Widgets")]


def ensure_app_groups(token: str) -> None:
    for identifier, _ in APP_GROUP_BUNDLES:
        _, res = api(token, "GET", "/bundleIds", params={"filter[identifier]": identifier,
                                                         "include": "bundleIdCapabilities", "limit": 5})
        match = [d for d in res.get("data", []) if d["attributes"]["identifier"] == identifier]
        if not match:
            print(f"   {identifier}: not registered yet (Xcode registers it on the first signed archive)")
            continue
        caps = {i["attributes"]["capabilityType"] for i in res.get("included", [])}
        if "APP_GROUPS" in caps:
            print(f"   {identifier}: App Groups already on")
            continue
        api(token, "POST", "/bundleIdCapabilities", body={"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": "APP_GROUPS"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": match[0]["id"]}}},
        }})
        print(f"   {identifier}: App Groups turned on")


def main() -> None:
    cfg = load_config()
    bundle = cfg["ASC_BUNDLE_ID"]
    token = make_token(cfg)

    print(f"==> bundle id {bundle}")
    _, res = api(token, "GET", "/bundleIds", params={"filter[identifier]": bundle, "limit": 1})
    if res.get("data"):
        print(f"   already registered (resource id {res['data'][0]['id']})")
    else:
        _, res = api(token, "POST", "/bundleIds", body={"data": {
            "type": "bundleIds",
            "attributes": {"identifier": bundle, "name": APP_NAME, "platform": "IOS"},
        }})
        print(f"   registered (resource id {res['data']['id']})")

    print("==> App Groups capability (widgets)")
    ensure_app_groups(token)

    print("==> App Store Connect app record")
    _, res = api(token, "GET", "/apps", params={"filter[bundleId]": bundle, "limit": 1})
    if not res.get("data"):
        print("   not created yet — Apple only allows this in the dashboard:")
        print("     https://appstoreconnect.apple.com/apps  ->  +  ->  New App")
        print("     Platform   iOS")
        print(f"     Name       {APP_NAME}")
        print("     Language   English (U.S.)")
        print(f"     Bundle ID  {bundle}")
        print(f"     SKU        {SKU}")
        print("     Access     Full Access")
        print("   then re-run this script.")
        raise SystemExit(2)

    app = res["data"][0]
    write_config_value("ASC_APP_ID", app["id"])
    write_config_value("ASC_APP_NAME", app["attributes"]["name"])
    print(f"   found app {app['id']} ({app['attributes']['name']!r}) — saved to asc-config.env")


if __name__ == "__main__":
    main()
