"""Keep Marracat's holiday App Store presence running every year without
anyone remembering to (owner, 2026-10-20: "lets do it all", with the
holiday ones recurring).

Daily (launchd, scripts/asc_growth/install_holidays_auto.sh), from
Marracat/Resources/holidays.json:
  1. lays out every holiday and standing event (new brands, the monthly
     brand spotlight) whose event starts in the next HORIZON days;
  2. makes its art (card 3840x2160, details 2160x3840 and, for a themed
     day, the product page header 3840x1646) and uploads what the Asset
     Library doesn't have yet;
  3. creates each event as a draft (an event with the same reference name is
     left alone), but only once a live version opens its link: collection
     links need the version that routes marracat://collection/<id>;
  4. sends the drafts and new art to App Review in one submission, unless
     one is already open (Apple allows one), in which case it tries again
     tomorrow;
  5. swaps the live product page's header to the day's approved header
     while its theme is on, and back to the everyday header video after.

Apple's rules (checked 2026-10-17 for Find A Crib's events): an event runs at
most 31 days, shows at most 14 days before it starts, 10 published and 15
approved at a time; its text can't change once approved. Placements can't be
edited (create and delete only), and only approved assets go on an approved
version.

    PYTHONPATH=scripts/asc_growth:~/projects/dhcr-map/ios/scripts \\
      ~/.venvs/dhcr-map/bin/python scripts/asc_growth/mc_holidays_auto.py            # plan only
    ... mc_holidays_auto.py --apply                                                  # do it
"""
import json
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from mc_growth import APP, call, library, upload

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
DOC = json.loads((ROOT / "Marracat/Resources/holidays.json").read_text())
CACHE = Path.home() / "Library/Caches/marracat-holidays"
# Items App Review rejected: never resubmitted by this job. Apple's reason is
# only on App Store Connect's App Review page, not in the API or the email,
# so a person reads it, fixes the event, and takes its name out of this file.
HELD = ROOT / "rejected.json"
HORIZON = 24          # days ahead an event's start may be when it's created (14 shown + 10 for review)
SHOW = 14             # Apple's longest lead before an event starts
NY = timedelta(hours=-5)   # midnight in New York, near enough across DST
COLLECTION_FROM = (1, 8)   # the first version that routes marracat://collection/<id>
EVERYDAY_HEADER = "marracat-2026-10b/default/header-video-3840x1646.mp4"
LIMITS = {"name": 30, "shortDescription": 50, "longDescription": 120}


def log(*a):
    print(datetime.now().isoformat(timespec="seconds"), *a, flush=True)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def midnight(d):
    return datetime(d.year, d.month, d.day, tzinfo=timezone.utc) - NY


def holiday_day(h, year):
    r = h["date"]
    if "day" in r:
        d = date(year, r["month"], r["day"])
    else:
        first = date(year, r["month"], 1)
        if r["nth"] > 0:
            d = first + timedelta(days=(r["weekday"] - first.isoweekday()) % 7 + 7 * (r["nth"] - 1))
        else:
            nxt = date(year + (r["month"] == 12), r["month"] % 12 + 1, 1)
            last = nxt - timedelta(days=1)
            d = last - timedelta(days=(last.isoweekday() - r["weekday"]) % 7)
    return d + timedelta(days=r.get("offset", 0))


def planned(today):
    """Every event starting within HORIZON days (or running now)."""
    out = []
    for h in DOC["holidays"]:
        for y in (today.year, today.year + 1):
            day = holiday_day(h, y)
            e = h["event"]
            start, end = day + timedelta(days=e["from"]), day + timedelta(days=e["to"])
            theme = None
            if h.get("theme"):
                theme = (day + timedelta(days=h["theme"]["from"]), day + timedelta(days=h["theme"]["to"]))
            out.append(dict(id=h["id"], ref=f"Holiday {h['id']} {y}", year=y, start=start, end=end, theme=theme,
                            line=h["line"], event=e, link=e["link"]))
    for s in DOC["standing"]:
        e = s["event"]
        if "once" in s:
            a, b = date.fromisoformat(s["once"]["from"]), date.fromisoformat(s["once"]["to"])
            out.append(dict(id=s["id"], ref=f"Standing {s['id']} {a.year}", year=a.year, start=a, end=b, theme=None,
                            line=s["line"], event=e, link=e["link"]))
        if "monthly" in s:
            for k in range(0, 3):
                y, m = today.year + (today.month - 1 + k) // 12, (today.month - 1 + k) % 12 + 1
                a = date(y, m, s["monthly"]["day"])
                brand = s["brands"][(y * 12 + m) % len(s["brands"])]
                out.append(dict(id=s["id"], ref=f"Standing {s['id']} {y}-{m:02d}", year=y, start=a,
                                end=a + timedelta(days=s["monthly"]["days"] - 1), theme=None, line=s["line"],
                                event=e, link=e["link"].replace("{brand}", brand)))
    return [p for p in out if p["end"] >= today and (p["start"] - today).days <= HORIZON]


def live_version():
    v = call("GET", f"/v1/apps/{APP}/appStoreVersions?filter[appStoreState]=READY_FOR_SALE&filter[platform]=IOS&limit=1")["data"]
    return v[0] if v else None


def opens(link, version):
    if not link.startswith("marracat://collection/"):
        return True
    have = tuple(int(x) for x in version["attributes"]["versionString"].split(".")[:2]) if version else (0, 0)
    return have >= COLLECTION_FROM


def art_files(p):
    """Card, details and (for a themed day) header PNGs, made once and cached."""
    from holiday_app_store_events import CSS, art
    import make_creative_assets as mca
    d = CACHE / str(p["year"]) / p["id"]
    d.mkdir(parents=True, exist_ok=True)
    files = {"card": d / "card-3840x2160.png", "details": d / "details-2160x3840.png"}
    if p["theme"]:
        # Animated, like the everyday header (owner, 2026-10-20).
        files["header"] = d / "header-video-3840x1646.mp4"
    if not all(f.exists() for f in (files["card"], files["details"])):
        from playwright.sync_api import sync_playwright
        from PIL import Image
        with sync_playwright() as pw:
            b = pw.chromium.launch()
            pg = b.new_page(viewport={"width": 3840, "height": 2160})
            for kind, (w, h) in {"card": (3840, 2160), "details": (2160, 3840)}.items():
                pg.set_viewport_size({"width": w, "height": h})
                pg.set_content(f'<!doctype html><html><head><style>{CSS} body{{margin:0}}</style></head>'
                               f'<body>{art(p["id"], p["line"], w, h, 0.62)}</body></html>')
                pg.screenshot(path=str(files[kind]))
                Image.open(files[kind]).convert("RGB").save(files[kind], optimize=True)
            b.close()
    if "header" in files and not files["header"].exists():
        h = next(x for x in DOC["holidays"] if x["id"] == p["id"])
        mca.holiday_header_video(files["header"], h)
    return files


def ref_for(p, kind):
    f = {"card": "card-3840x2160.png", "details": "details-2160x3840.png", "header": "header-video-3840x1646.mp4"}[kind]
    return f"marracat-holidays/{p['year']}/{p['id']}/{f}"


def spec(p):
    e = p["event"]
    s, end = midnight(p["start"]), midnight(p["end"] + timedelta(days=1)) - timedelta(minutes=1)
    out = {"referenceName": p["ref"], "badge": e["badge"].upper().replace(" ", "_"),
           "purpose": "APPROPRIATE_FOR_ALL_USERS", "priority": "NORMAL", "territories": ["USA"],
           "publishStart": iso(s - timedelta(days=SHOW)), "eventStart": iso(s), "eventEnd": iso(end),
           "deepLink": p["link"], "purchaseRequirement": "NO_COST_ASSOCIATED",
           "name": e["name"], "shortDescription": e["short"], "longDescription": e["long"],
           "card": ref_for(p, "card"), "details": ref_for(p, "details")}
    for k, n in LIMITS.items():
        assert len(out[k]) <= n, (p["ref"], k)
    return out


def open_submission():
    for r in call("GET", f"/v1/reviewSubmissions?filter[app]={APP}&filter[platform]=IOS&limit=20")["data"]:
        if r["attributes"].get("state") in ("READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"):
            return r["id"], r["attributes"]["state"]
    return None, None


def held():
    try:
        return set(json.loads(HELD.read_text()))
    except (OSError, ValueError, TypeError):
        return set()


def clear_rejections(apply):
    """Take App Review's rejected items out of a submission stuck in
    UNRESOLVED_ISSUES. Apple holds every item, accepted ones too, until the
    rejected ones go, and while it sits there this job can't submit anything
    (Black Friday + Gift Guide events, 7ad6a467, 2026-10-28)."""
    sid, st = open_submission()
    if st != "UNRESOLVED_ISSUES":
        return
    r = call("GET", f"/v1/reviewSubmissions/{sid}/items?limit=50&include=appEvent,appAssetLibraryVideo")
    names = {i["id"]: (i.get("attributes") or {}).get("referenceName") for i in r.get("included", [])}
    keep = held()
    for it in r["data"]:
        if (it.get("attributes") or {}).get("state") != "REJECTED":
            continue
        ids = [x["data"]["id"] for x in (it.get("relationships") or {}).values()
               if isinstance(x, dict) and isinstance(x.get("data"), dict)]
        name = next((names[i] for i in ids if names.get(i)), it["id"])
        log(f"rejected {name} in {sid[:8]}: {'taking it out' if apply else 'would take it out'}; "
            f"reason is on ASC > App Review; held in {HELD.name}")
        if apply:
            call("PATCH", f"/v1/reviewSubmissionItems/{it['id']}", {"data": {
                "type": "reviewSubmissionItems", "id": it["id"], "attributes": {"removed": True}}})
            keep.add(name)
    if apply and keep != held():
        HELD.write_text(json.dumps(sorted(keep), indent=1))


def submit(apply):
    """Draft events and unreviewed holiday art, in one submission."""
    skip = held()
    drafts = [e for e in call("GET", f"/v1/apps/{APP}/appEvents?limit=200")["data"]
              if e["attributes"].get("eventState") == "DRAFT"
              and e["attributes"].get("referenceName") not in skip]
    items = [("appEvent", "appEvents", e["id"], e["attributes"]["referenceName"]) for e in drafts]
    items += [("appAssetLibraryVideo", "appAssetLibraryVideos", i["id"], i["attributes"]["referenceName"])
              for i in library("videos", "CREATIVE_ASSETS")
              if i["attributes"].get("state") == "PREPARE_FOR_SUBMISSION"
              and i["attributes"].get("referenceName", "").startswith("marracat-holidays/")
              and "/header-video-" in i["attributes"]["referenceName"]
              and i["attributes"]["referenceName"] not in skip]
    if not items:
        return
    names = ", ".join(x[3] for x in items)
    sid, st = open_submission()
    # READY_FOR_REVIEW = a submission this job opened and never sent (a 409
    # mid-way, 2026-10-24): finish it rather than wait on it forever.
    if sid and st != "READY_FOR_REVIEW":
        log(f"wait     {names}: submission {sid[:8]} is {st}")
        return
    if not apply:
        log(f"would submit {names}")
        return
    # Apple 409s an event whose publish date has passed (TERRITORY_SCHEDULES_
    # DATES_IN_PAST), e.g. a draft that waited out a version's review.
    soon = datetime.now(timezone.utc) + timedelta(hours=2)
    for e in drafts:
        ts = e["attributes"].get("territorySchedules") or []
        if any(datetime.fromisoformat(t[k].replace("Z", "+00:00")) < soon
               for t in ts for k in ("publishStart", "eventStart")):
            new = [{**t, **{k: iso(soon) for k in ("publishStart", "eventStart")
                            if datetime.fromisoformat(t[k].replace("Z", "+00:00")) < soon}} for t in ts]
            call("PATCH", f"/v1/appEvents/{e['id']}", {"data": {"type": "appEvents", "id": e["id"],
                 "attributes": {"territorySchedules": new}}})
            log(f"moved    {e['attributes']['referenceName']} to start showing {iso(soon)}")
    if sid:
        sub = {"id": sid}
        inside = call("GET", f"/v1/reviewSubmissions/{sid}/items?limit=50&include=appEvent,appAssetLibraryVideo")["data"]
        have = {r["data"]["id"] for i in inside for r in (i.get("relationships") or {}).values()
                if isinstance(r, dict) and isinstance(r.get("data"), dict)}
        items = [x for x in items if x[2] not in have]
    else:
        sub = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                   "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
    for rel, typ, iid, _ in items:
        call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub["id"]}},
            rel: {"data": {"type": typ, "id": iid}}}}})
    d = call("PATCH", f"/v1/reviewSubmissions/{sub['id']}", {"data": {"type": "reviewSubmissions", "id": sub["id"],
             "attributes": {"submitted": True}}})["data"]
    log(f"submitted {names} as {sub['id'][:8]} ({d['attributes'].get('state')})")


def assets():
    out = {}
    for kind in ("images", "videos"):
        for i in library(kind, "CREATIVE_ASSETS"):
            a = i["attributes"]
            if a.get("state") != "ARCHIVED":
                out[a.get("referenceName")] = (kind[:-1], i["id"], a.get("state"))
    return out


def swap_header(today, version, have, apply):
    """The live version's header: the themed day's approved header, or the
    everyday video. Apple can't edit a placement, so swap = delete + create,
    putting the old one back if the create fails."""
    if not version:
        return
    want = EVERYDAY_HEADER
    for h in DOC["holidays"]:
        if not h.get("theme"):
            continue
        for y in (today.year - 1, today.year, today.year + 1):
            day = holiday_day(h, y)
            a, b = day + timedelta(days=h["theme"]["from"]), day + timedelta(days=h["theme"]["to"])
            ref = f"marracat-holidays/{y}/{h['id']}/header-video-3840x1646.mp4"
            if a <= today <= b and have.get(ref, (0, 0, ""))[2] == "APPROVED":
                if want == EVERYDAY_HEADER or (b - a) < span:   # the shortest theme wins, as in the app
                    want, span = ref, b - a
    if want not in have:
        log(f"header   {want} isn't in the library; left as is")
        return
    # Apple refuses to delete a placement while a product page A/B test runs
    # (409 STATE_ERROR.EXPERIMENT_IN_PROGRESS, 2026-10-25), so wait it out.
    now = datetime.now(timezone.utc)
    for x in call("GET", f"/v1/apps/{APP}/appStoreVersionExperimentsV2?limit=50")["data"]:
        a = x["attributes"]
        if a.get("startDate") and a.get("endDate") and \
                datetime.fromisoformat(a["startDate"]) <= now < datetime.fromisoformat(a["endDate"]):
            log(f"header   kept: A/B test '{a.get('name')}' runs until {a['endDate'][:10]} (wanted {want})")
            return
    by_id = {v[1]: r for r, v in have.items()}
    for loc in call("GET", f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]:
        for p in call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/placements?limit=200&include=image,video")["data"]:
            if p["attributes"]["placementType"] != "PRODUCT_PAGE_HEADER_ASSET":
                continue
            r = p["relationships"]
            cur = (r.get("image", {}).get("data") or r.get("video", {}).get("data") or {}).get("id")
            if by_id.get(cur) == want:
                continue
            log(("swap" if apply else "would swap"), loc["attributes"]["locale"], by_id.get(cur), "->", want)
            if not apply:
                continue
            kind, new_id, _ = have[want]
            call("DELETE", f"/v1/appAssetLibraryPlacements/{p['id']}")
            try:
                place(kind, new_id, loc["id"])
            except BaseException:
                old = have.get(by_id.get(cur, ""), ("video",))[0]
                place(old, cur, loc["id"])
                raise


def place(kind, asset_id, loc_id):
    return call("POST", "/v1/appAssetLibraryPlacements", {"data": {"type": "appAssetLibraryPlacements",
        "attributes": {"placementType": "PRODUCT_PAGE_HEADER_ASSET", "placementGroup": "DEFAULT_PROFILE"},
        "relationships": {kind: {"data": {"type": "appAssetLibraryVideos" if kind == "video" else "appAssetLibraryImages", "id": asset_id}},
                          "appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})["data"]


def main():
    import asc_app_events
    apply = "--apply" in sys.argv
    today = datetime.now(timezone.utc).astimezone(timezone(NY)).date()
    log(f"==> {today} ({'apply' if apply else 'plan only'})")
    version = live_version()
    log("live version", version["attributes"]["versionString"] if version else None)
    events = {e["attributes"]["referenceName"] for e in call("GET", f"/v1/apps/{APP}/appEvents?limit=200")["data"]}
    have = assets()
    for p in sorted(planned(today), key=lambda x: x["start"]):
        if p["ref"] in events:
            continue
        if not opens(p["link"], version):
            log(f"later    {p['ref']}: {p['link']} needs version {'.'.join(map(str, COLLECTION_FROM))} live")
            continue
        if not apply:
            log(f"would create {p['ref']}: {p['start']} to {p['end']} ({p['link']})")
            continue
        files = art_files(p)
        for kind, f in files.items():
            ref = ref_for(p, kind)
            if ref not in have:
                kind_ = "video" if f.suffix == ".mp4" else "image"
                iid, a = upload(kind_, f, ref, "CREATIVE_ASSETS")
                have[ref] = (kind_, iid, a.get("state"))
                log(f"uploaded {ref} ({a.get('state')})")
        s = spec(p)
        if datetime.fromisoformat(s["eventStart"].replace("Z", "+00:00")) < datetime.now(timezone.utc):
            s["eventStart"] = iso(datetime.now(timezone.utc) + timedelta(hours=1))
        if datetime.fromisoformat(s["publishStart"].replace("Z", "+00:00")) < datetime.now(timezone.utc):
            s["publishStart"] = iso(datetime.now(timezone.utc) + timedelta(hours=1))
        asc_app_events.create(APP, s)
    clear_rejections(apply)
    submit(apply)
    swap_header(today, version, assets() if apply else have, apply)


if __name__ == "__main__":
    main()
