"""Swap Marracat's live header/search creative assets for the safe-area set
(prefix marracat-2026-10b, 2026-10-12) once App Review approves it.

The first set (marracat-2026-10) ignored Apple's art safe area: on an iPhone
17 Pro the header video showed "/ARRACA" under the back and mute/share
buttons and cut every tagline at both edges. Apple places only APPROVED
assets on an approved parent (the live 1.4 version, the approved custom
product pages), and placements can't be updated (CREATE, DELETE only), so
this waits for approval, then for each live placement deletes the old one
and creates the new one, putting the old asset back if the create fails.

    PYTHONPATH=scripts/asc_growth:~/projects/dhcr-map/ios/scripts \\
      ~/.venvs/dhcr-map/bin/python scripts/asc_growth/mc_swap_creatives.py [--once] [--dry-run]
"""
import argparse, sys, time
from datetime import datetime
from mc_growth import call, library, APP

OLD, NEW = "marracat-2026-10/", "marracat-2026-10b/"
VERSION = "181c72bf-2501-4706-8c03-a09963028185"   # 1.4, READY_FOR_SALE
# slot -> reference name (under the prefix) used in it
SLOTS = {
    ("version", "PRODUCT_PAGE_HEADER_ASSET"): "default/header-video-3840x1646.mp4",
    ("version", "APP_STORE_SEARCH_RESULTS_ASSET"): "default/search-3840x2560.png",
    ("Skincare & Hair Care", "PRODUCT_PAGE_HEADER_ASSET"): "cpp-beauty/header-3840x1646.png",
    ("Gifts", "PRODUCT_PAGE_HEADER_ASSET"): "cpp-gifts/header-3840x1646.png",
    ("Deals & Price Alerts", "PRODUCT_PAGE_HEADER_ASSET"): "cpp-deals/header-3840x1646.png",
}
for cpp in ("Skincare & Hair Care", "Gifts", "Deals & Price Alerts"):
    SLOTS[(cpp, "APP_STORE_SEARCH_RESULTS_ASSET")] = "default/search-3840x2560.png"


def log(*a):
    print(datetime.now().isoformat(timespec="seconds"), *a, flush=True)


def assets():
    out = {}
    for kind in ("images", "videos"):
        for i in library(kind, "CREATIVE_ASSETS"):
            a = i["attributes"]
            if a.get("state") != "ARCHIVED":
                out[a.get("referenceName")] = (kind[:-1], i["id"], a.get("state"))
    return out


def parents():
    """(label, relationship, type, id) for every localization that carries placements."""
    out = [("version", "appStoreVersionLocalization", "appStoreVersionLocalizations", loc["id"])
           for loc in call("GET", f"/v1/appStoreVersions/{VERSION}/appStoreVersionLocalizations")["data"]]
    for p in call("GET", f"/v1/apps/{APP}/appCustomProductPages?limit=50")["data"]:
        for v in call("GET", f"/v1/appCustomProductPages/{p['id']}/appCustomProductPageVersions")["data"]:
            if v["attributes"].get("state") != "APPROVED":
                continue
            for loc in call("GET", f"/v1/appCustomProductPageVersions/{v['id']}/appCustomProductPageLocalizations")["data"]:
                out.append((p["attributes"]["name"], "appCustomProductPageLocalization",
                            "appCustomProductPageLocalizations", loc["id"]))
    return out


def create(ptype, kind, asset_id, rel, typ, pid):
    return call("POST", "/v1/appAssetLibraryPlacements", {"data": {"type": "appAssetLibraryPlacements",
        "attributes": {"placementType": ptype, "placementGroup": "DEFAULT_PROFILE"},
        "relationships": {kind: {"data": {"type": "appAssetLibraryVideos" if kind == "video" else "appAssetLibraryImages",
                                          "id": asset_id}},
                          rel: {"data": {"type": typ, "id": pid}}}}})["data"]


def swap(dry):
    have = assets()
    wanted = {NEW + ref for ref in SLOTS.values()}
    states = {r: have.get(r, (None, None, "MISSING"))[2] for r in sorted(wanted)}
    if any(s == "REJECTED" for s in states.values()):
        log("rejected:", states)
        return 1
    if any(s != "APPROVED" for s in states.values()):
        log("waiting:", states)
        return None
    by_id = {v[1]: r for r, v in have.items()}
    for label, rel, typ, pid in parents():
        path = f"/v1/{typ}/{pid}/placements?limit=200&include=image,video"   # relationships only come with include
        for p in call("GET", path)["data"]:
            ptype = p["attributes"]["placementType"]
            ref = SLOTS.get((label, ptype))
            if not ref:
                continue
            r = p["relationships"]
            cur = (r.get("image", {}).get("data") or r.get("video", {}).get("data") or {}).get("id")
            cur_ref = by_id.get(cur, "")
            if cur_ref == NEW + ref:
                log("already", label, ptype)
                continue
            kind, new_id, _ = have[NEW + ref]
            log(("would swap" if dry else "swap"), label, ptype, cur_ref, "->", NEW + ref)
            if dry:
                continue
            call("DELETE", f"/v1/appAssetLibraryPlacements/{p['id']}")
            try:
                n = create(ptype, kind, new_id, rel, typ, pid)
                log("  placed", n["id"], n["attributes"].get("state"))
            except BaseException as e:   # call() exits on HTTP errors: put the old one back
                log("  create failed, restoring", cur_ref, e)
                old_kind = "video" if cur_ref.endswith(".mp4") else "image"
                create(ptype, old_kind, cur, rel, typ, pid)
                raise
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--every", type=int, default=900)
    ap.add_argument("--hours", type=float, default=96)
    a = ap.parse_args()
    deadline = time.time() + a.hours * 3600
    while True:
        try:
            rc = swap(a.dry_run)
        except (Exception, SystemExit) as e:   # call() sys.exits on an HTTP error
            log("poll failed:", e)
            rc = None
        if rc is not None:
            return rc
        if a.once or time.time() > deadline:
            return 2
        time.sleep(a.every)


if __name__ == "__main__":
    sys.exit(main())
