"""Adds every Marracat draft (the 1.4 version, custom product page versions,
experiments, Asset Library images/videos) to one review submission; send it
with PATCH submitted:true. Apple refuses an experiment next to a version, and
assets placed on a version/CPP are reviewed embedded with it (409
BLOCKED_BY_EMBEDDED_REVIEW as standalone items) -- both are expected failures.
Run with PYTHONPATH=~/projects/dhcr-map/ios/scripts (asc_creative_assets)."""
import requests, json
from mc_growth import *
from asc_creative_assets import _headers
V = "181c72bf-2501-4706-8c03-a09963028185"
open_subs = call("GET", f"/v1/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES")["data"]
print("open:", [(s["id"], s["attributes"]["state"]) for s in open_subs])
items = [("appStoreVersion", "appStoreVersions", V, "version 1.4 (132)")]
for p in call("GET", f"/v1/apps/{APP}/appCustomProductPages?limit=50")["data"]:
    for v in call("GET", f"/v1/appCustomProductPages/{p['id']}/appCustomProductPageVersions")["data"]:
        if v["attributes"].get("state") == "PREPARE_FOR_SUBMISSION":
            items.append(("appCustomProductPageVersion", "appCustomProductPageVersions", v["id"], "CPP " + p["attributes"]["name"]))
for x in call("GET", f"/v1/apps/{APP}/appStoreVersionExperimentsV2?limit=50")["data"]:
    if x["attributes"].get("state") == "PREPARE_FOR_SUBMISSION":
        items.append(("appStoreVersionExperimentV2", "appStoreVersionExperiments", x["id"], "A/B " + x["attributes"]["name"]))
for i in library("images", "CREATIVE_ASSETS"):
    if i["attributes"].get("state") == "PREPARE_FOR_SUBMISSION":
        items.append(("appAssetLibraryImage", "appAssetLibraryImages", i["id"], i["attributes"]["referenceName"]))
for i in library("videos", "CREATIVE_ASSETS"):
    if i["attributes"].get("state") == "PREPARE_FOR_SUBMISSION":
        items.append(("appAssetLibraryVideo", "appAssetLibraryVideos", i["id"], i["attributes"]["referenceName"]))
draft = [s for s in open_subs if s["attributes"]["state"] == "READY_FOR_REVIEW"]
assert len(draft) == len(open_subs), "another submission is in review; one per platform"
sub = draft[0] if draft else call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions",
      "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
print("submission", sub["id"])
ok, bad = [], []
for rel, typ, iid, label in items:
    r = requests.post(API + "/v1/reviewSubmissionItems", headers=_headers(), timeout=60, json={"data": {
        "type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
            rel: {"data": {"type": typ, "id": iid}}}}})
    (ok if r.ok else bad).append(label)
    print("added " if r.ok else "FAILED", label, "" if r.ok else r.text[:1500])
json.dump({"sub": sub["id"], "ok": ok, "bad": bad}, open("submission_state.json", "w"))
