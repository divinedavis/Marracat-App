import json, sys
from mc_growth import *
from asc_product_pages import create_page, live_version

PAGES = [
 ("beauty", "Skincare & Hair Care", "Skincare, body care and hair care from independent brands. Browse every aisle, save your favorites and check out with each brand right in the app."),
 ("gifts", "Gifts", "Find gifts from independent brands: jewelry, candles, gift sets and more. Save ideas to a list and check out with each brand right in the app."),
 ("deals", "Deals & Price Alerts", "Shop deals from independent brands. Track any price or follow a brand's sales, and Marracat lets you know when it drops."),
]
imgs = {i["attributes"]["referenceName"]: i["id"] for i in library("images", "CREATIVE_ASSETS") + library("images", "APP_SCREENSHOTS_AND_PREVIEWS")
        if i["attributes"].get("state") != "ARCHIVED"}
existing = {p["attributes"]["name"]: p for p in call("GET", f"/v1/apps/{APP}/appCustomProductPages?limit=50")["data"]}
ver = live_version(APP)
out = {}
for slug, name, promo in PAGES:
    assert len(promo) <= 170, (slug, len(promo))
    if name in existing:
        print("exists", name); continue
    cpp, cv = create_page(APP, ver, name, promo)
    loc = call("GET", f"/v1/appCustomProductPageVersions/{cv}/appCustomProductPageLocalizations")["data"][0]["id"]
    pl = call("GET", f"/v1/appCustomProductPageLocalizations/{loc}/placements?limit=200")["data"]
    groups = {}
    for p in pl:
        groups.setdefault((p["attributes"]["placementType"], p["attributes"]["placementGroup"]), []).append(p["id"])
    print(name, {f"{k[0]}/{k[1]}": len(v) for k, v in groups.items()})
    # header + search
    for ptype, ref in (("PRODUCT_PAGE_HEADER_ASSET", f"marracat-2026-10/cpp-{slug}/header-3840x1646.png"),
                       ("APP_STORE_SEARCH_RESULTS_ASSET", "marracat-2026-10/default/search-3840x2560.png")):
        for pid in groups.get((ptype, "DEFAULT_PROFILE"), []):
            call("DELETE", f"/v1/appAssetLibraryPlacements/{pid}")
        place(ptype, "DEFAULT_PROFILE", "image", imgs[ref], "appCustomProductPageLocalization", "appCustomProductPageLocalizations", loc)
    # iPhone screenshots: replace the copied set with this page's panels
    g = "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"
    for (ptype, grp), ids in groups.items():
        if ptype == "APP_SCREENSHOT" and grp.startswith("IPHONE"):
            for pid in ids: call("DELETE", f"/v1/appAssetLibraryPlacements/{pid}")
    refs = sorted(r for r in imgs if r.startswith(f"marracat-2026-10/cpp-{slug}/0"))
    new = [place("APP_SCREENSHOT", g, "image", imgs[r], "appCustomProductPageLocalization", "appCustomProductPageLocalizations", loc)["id"] for r in refs]
    call("POST", "/v1/appAssetLibraryPlacementOrderingRequests", {"data": {
        "type": "appAssetLibraryPlacementOrderingRequests", "attributes": {"placementGroup": g},
        "relationships": {"orderedPlacements": {"data": [{"type": "appAssetLibraryPlacements", "id": i} for i in new]},
                          "appCustomProductPageLocalization": {"data": {"type": "appCustomProductPageLocalizations", "id": loc}}}}})
    url = call("GET", f"/v1/appCustomProductPages/{cpp['id']}")["data"]["attributes"].get("url")
    out[name] = {"id": cpp["id"], "version": cv, "url": url}
    print("created", name, url, len(new), "screens")
print(json.dumps(out, indent=1))
