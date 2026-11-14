"""Marracat App Store growth helpers (2026-10-11): Asset Library video and
screenshot uploads, placements. mc_cpp.py makes the custom product pages,
mc_exp.py the "Lead with deals" A/B test, mc_submit.py the review submission.

    PYTHONPATH=~/projects/dhcr-map/ios/scripts ~/.venvs/dhcr-map/bin/python scripts/asc_growth/mc_cpp.py

Needs dhcr-map's asc_creative_assets.py (origin/main, with asc_product_pages.py)
and its asc-config.env (team-wide API key)."""
import sys, time, requests
from pathlib import Path
from asc_creative_assets import call, API, _headers

APP = "6810905687"

def upload(kind, f, ref, category, extra=None):
    f = Path(f).expanduser(); data = f.read_bytes()
    typ = "appAssetLibraryVideos" if kind == "video" else "appAssetLibraryImages"
    attrs = {"category": category, "fileName": f.name, "fileSize": len(data), "referenceName": ref}
    attrs.update(extra or {})
    d = call("POST", f"/v1/{typ}", {"data": {"type": typ, "attributes": attrs,
        "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": APP}}}}})["data"]
    for op in d["attributes"].get("uploadOperations") or []:
        hdrs = {h["name"]: h["value"] for h in op.get("requestHeaders") or []}
        r = requests.request(op["method"], op["url"], headers=hdrs, data=data[op["offset"]:op["offset"] + op["length"]], timeout=600)
        if r.status_code >= 400: sys.exit(f"chunk failed {r.status_code} {r.text[:300]}")
    call("PATCH", f"/v1/{typ}/{d['id']}", {"data": {"type": typ, "id": d["id"], "attributes": {"uploaded": True}}})
    for _ in range(100):
        a = call("GET", f"/v1/{typ}/{d['id']}")["data"]["attributes"]
        if a.get("state") not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"): break
        time.sleep(4)
    return d["id"], a

def library(kind="images", category="CREATIVE_ASSETS"):
    out, path = [], f"/v1/appAssetLibraries/{APP}/{kind}?limit=200&filter[category]={category}"
    while path:
        d = call("GET", path); out += d["data"]
        n = d.get("links", {}).get("next"); path = n[len(API):] if n else None
    return out

def place(ptype, group, asset_kind, asset_id, parent_rel, parent_type, parent_id):
    rel = {"image": ("appAssetLibraryImages")} 
    return call("POST", "/v1/appAssetLibraryPlacements", {"data": {"type": "appAssetLibraryPlacements",
        "attributes": {"placementType": ptype, "placementGroup": group},
        "relationships": {asset_kind: {"data": {"type": "appAssetLibraryVideos" if asset_kind == "video" else "appAssetLibraryImages", "id": asset_id}},
                          parent_rel: {"data": {"type": parent_type, "id": parent_id}}}}})["data"]
