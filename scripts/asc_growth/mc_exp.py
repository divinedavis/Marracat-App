from mc_growth import *
NAME, TREAT = "Lead with deals", "Deals screenshot first"
if any(x["attributes"].get("name") == NAME for x in call("GET", f"/v1/apps/{APP}/appStoreVersionExperimentsV2?limit=50")["data"]):
    raise SystemExit("exists")
deals = next(i["id"] for i in library("images", "APP_SCREENSHOTS_AND_PREVIEWS") if i["attributes"].get("referenceName") == "marracat-2026-10/cpp-experiment/01-deals.png")
x = call("POST", "/v2/appStoreVersionExperiments", {"data": {"type": "appStoreVersionExperiments",
    "attributes": {"name": NAME, "platform": "IOS", "trafficProportion": 50},
    "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
t = call("POST", "/v1/appStoreVersionExperimentTreatments", {"data": {"type": "appStoreVersionExperimentTreatments",
    "attributes": {"name": TREAT},
    "relationships": {"appStoreVersionExperimentV2": {"data": {"type": "appStoreVersionExperiments", "id": x["id"]}}}}})["data"]
loc = call("POST", "/v1/appStoreVersionExperimentTreatmentLocalizations", {"data": {"type": "appStoreVersionExperimentTreatmentLocalizations",
    "attributes": {"locale": "en-US"},
    "relationships": {"appStoreVersionExperimentTreatment": {"data": {"type": "appStoreVersionExperimentTreatments", "id": t["id"]}}}}})["data"]
d = call("GET", f"/v1/appStoreVersionExperimentTreatmentLocalizations/{loc['id']}/placements?limit=200&include=image")
names = {i["id"]: i["attributes"].get("fileName") for i in d.get("included", [])}
g = "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"
shots = [p for p in d["data"] if p["attributes"]["placementType"] == "APP_SCREENSHOT" and p["attributes"]["placementGroup"] == g]
fname = lambda p: names.get(p["relationships"]["image"]["data"]["id"], "")
print("copied:", sorted(fname(p) for p in shots), {p["attributes"]["placementType"] for p in d["data"]})
new = place("APP_SCREENSHOT", g, "image", deals, "appStoreVersionExperimentTreatmentLocalization", "appStoreVersionExperimentTreatmentLocalizations", loc["id"])
order = [new["id"]] + [p["id"] for p in sorted(shots, key=fname)]   # live order = 01-..08- file names
call("POST", "/v1/appAssetLibraryPlacementOrderingRequests", {"data": {"type": "appAssetLibraryPlacementOrderingRequests",
    "attributes": {"placementGroup": g},
    "relationships": {"orderedPlacements": {"data": [{"type": "appAssetLibraryPlacements", "id": i} for i in order]},
                      "appStoreVersionExperimentTreatmentLocalization": {"data": {"type": "appStoreVersionExperimentTreatmentLocalizations", "id": loc["id"]}}}}})
print("experiment", x["id"], x["attributes"].get("state"), "treatment", t["id"], "screens", len(order))
