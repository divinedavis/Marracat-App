#!/usr/bin/env python3
"""Replace one display size's screenshots and app preview on the editable
App Store version (owner, 2026-11-01: the white Futura set and the 28 s
preview from app-store/listing-2026-11 were approved).

    ~/.venvs/marracat/bin/python scripts/asc_listing_media.py \
        --screens app-store/listing-2026-11/out/white/*.png \
        --preview app-store/listing-2026-11/out/marracat-preview-886x1920.mp4 \
        [--display APP_IPHONE_67] [--locale en-US] [--poster 00:00:05:00] [--dry-run]

Only a version still being prepared can change (the live one can't); its
screenshots and preview go public when that version is released. The
display's existing screenshots and preview set are deleted, then the new
files upload in order through Apple's reservations with MD5 checksums, and
each must finish processing. Other sizes (iPad) are left alone.
"""
import argparse
import hashlib
import pathlib
import sys
import time
from urllib.parse import urlsplit

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
# Bound in main(): asc needs requests, which the repo's test runner (system
# Python) doesn't have; the tests put a fake in `api`.
api = load_config = make_token = None

EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}


def put_parts(operations, blob, label):
    if not operations:
        return
    import requests
    for op in operations:
        url = urlsplit(op["url"])
        if url.scheme != "https" or not url.hostname:
            raise SystemExit("Apple returned an invalid upload URL")
        start, size = op["offset"], op["length"]
        r = requests.request(op["method"], op["url"], headers={h["name"]: h["value"] for h in op["requestHeaders"]},
                             data=blob[start:start + size], timeout=120, allow_redirects=False)
        if not 200 <= r.status_code < 300:
            raise SystemExit(f"{label}: upload part returned HTTP {r.status_code}")


def wait_done(token, path, label, tries=90, every=4):
    for _ in range(tries):
        _, r = api(token, "GET", path)
        state = r["data"]["attributes"]["assetDeliveryState"]
        if state["state"] == "COMPLETE":
            print(f"  {label}: COMPLETE", flush=True)
            return r["data"]
        if state["state"] == "FAILED":
            raise SystemExit(f"{label}: processing failed: {state.get('errors')}")
        time.sleep(every)
    raise SystemExit(f"{label}: still processing; check App Store Connect before retrying")


def localization(token, app_id, locale):
    _, r = api(token, "GET", f"/apps/{app_id}/appStoreVersions",
               params={"limit": 10, "fields[appStoreVersions]": "versionString,appStoreState"})
    version = next((v for v in r["data"] if v["attributes"]["appStoreState"] in EDITABLE), None)
    if not version:
        raise SystemExit("no App Store version is being prepared; open one with scripts/create_version.py")
    _, r = api(token, "GET", f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
               params={"fields[appStoreVersionLocalizations]": "locale"})
    loc = next((l for l in r["data"] if l["attributes"]["locale"] == locale), None)
    if not loc:
        raise SystemExit(f"version {version['attributes']['versionString']} has no {locale} localization")
    return version["attributes"]["versionString"], loc["id"]


def replace_screens(token, loc_id, display, files, dry):
    _, r = api(token, "GET", f"/appStoreVersionLocalizations/{loc_id}/appScreenshotSets",
               params={"fields[appScreenshotSets]": "screenshotDisplayType"})
    target = next((s for s in r["data"] if s["attributes"]["screenshotDisplayType"] == display), None)
    blobs = []
    for path in files:
        blob = path.read_bytes()
        if not blob.startswith(b"\x89PNG\r\n\x1a\n"):
            raise SystemExit(f"{path}: expected a PNG")
        blobs.append((path, blob, hashlib.md5(blob).hexdigest()))
    # A re-run keeps what an earlier run already sent (same name, same
    # bytes, uploaded): Apple can take minutes to process a screenshot.
    kept, stale = {}, []
    if target:
        _, r = api(token, "GET", f"/appScreenshotSets/{target['id']}/appScreenshots",
                   params={"fields[appScreenshots]": "fileName,sourceFileChecksum,assetDeliveryState"})
        wanted = {p.name: md5 for p, _, md5 in blobs}
        for s in r["data"]:
            a = s["attributes"]
            state = (a.get("assetDeliveryState") or {}).get("state")
            if wanted.get(a["fileName"]) == a.get("sourceFileChecksum") and state in ("COMPLETE", "UPLOAD_COMPLETE") \
                    and a["fileName"] not in kept:
                kept[a["fileName"]] = s["id"]
            else:
                stale.append(s)
        print(f"{display}: keeping {len(kept)}, deleting {len(stale)}", flush=True)
        if not dry:
            for s in stale:
                api(token, "DELETE", f"/appScreenshots/{s['id']}", ok_statuses=(404,))
    elif not dry:
        _, r = api(token, "POST", "/appScreenshotSets", body={"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
        target = r["data"]
    order = []
    for path, blob, md5 in blobs:
        if path.name in kept:
            order.append(kept[path.name])
            continue
        print(f"{display}: uploading {path.name} ({len(blob) // 1024} KB)", flush=True)
        if dry:
            continue
        _, r = api(token, "POST", "/appScreenshots", body={"data": {
            "type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(blob)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": target["id"]}}}}})
        shot = r["data"]
        put_parts(shot["attributes"]["uploadOperations"], blob, path.name)
        api(token, "PATCH", f"/appScreenshots/{shot['id']}", body={"data": {
            "type": "appScreenshots", "id": shot["id"], "attributes": {"uploaded": True, "sourceFileChecksum": md5}}})
        order.append(shot["id"])
    if dry:
        return
    for (path, _, _), sid in zip(blobs, order):
        wait_done(token, f"/appScreenshots/{sid}", path.name, tries=120, every=3)
    # The files' order, whatever order they finished in.
    api(token, "PATCH", f"/appScreenshotSets/{target['id']}/relationships/appScreenshots",
        body={"data": [{"type": "appScreenshots", "id": sid} for sid in order]})
    print(f"{display}: {len(order)} screenshots in order", flush=True)


def replace_preview(token, loc_id, display, path, poster, dry):
    # Previews name the slot without the screenshots' "APP_" ("IPHONE_67").
    display = display.removeprefix("APP_")
    blob = path.read_bytes()
    _, r = api(token, "GET", f"/appStoreVersionLocalizations/{loc_id}/appPreviewSets",
               params={"fields[appPreviewSets]": "previewType"})
    for s in r["data"]:
        if s["attributes"]["previewType"] == display:
            print(f"{display}: deleting the existing preview set", flush=True)
            if not dry:
                api(token, "DELETE", f"/appPreviewSets/{s['id']}", ok_statuses=(404,))
    print(f"{display}: uploading preview {path.name} ({len(blob) // 1048576} MB)", flush=True)
    if dry:
        return
    _, r = api(token, "POST", "/appPreviewSets", body={"data": {
        "type": "appPreviewSets", "attributes": {"previewType": display},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
    set_id = r["data"]["id"]
    _, r = api(token, "POST", "/appPreviews", body={"data": {
        "type": "appPreviews", "attributes": {"fileName": path.name, "fileSize": len(blob), "mimeType": "video/mp4"},
        "relationships": {"appPreviewSet": {"data": {"type": "appPreviewSets", "id": set_id}}}}})
    preview = r["data"]
    put_parts(preview["attributes"]["uploadOperations"], blob, path.name)
    api(token, "PATCH", f"/appPreviews/{preview['id']}", body={"data": {
        "type": "appPreviews", "id": preview["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
    wait_done(token, f"/appPreviews/{preview['id']}", path.name, tries=150, every=6)
    if poster:
        # The poster can only be set once Apple has made the preview image,
        # a little after the video itself is COMPLETE (409 until then).
        for _ in range(40):
            status, _ = api(token, "PATCH", f"/appPreviews/{preview['id']}", body={"data": {
                "type": "appPreviews", "id": preview["id"], "attributes": {"previewFrameTimeCode": poster}}},
                ok_statuses=(409,))
            if status < 300:
                print(f"  poster frame {poster}", flush=True)
                break
            time.sleep(6)
        else:
            print(f"  poster frame not set; set {poster} in App Store Connect", flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--screens", nargs="*", type=pathlib.Path, default=[])
    ap.add_argument("--preview", type=pathlib.Path)
    ap.add_argument("--display", default="APP_IPHONE_67")
    ap.add_argument("--locale", default="en-US")
    ap.add_argument("--poster", default="00:00:05:00", help="preview poster frame, HH:MM:SS:FF")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    global api, load_config, make_token
    from asc import api, load_config, make_token
    if not args.screens and not args.preview:
        raise SystemExit("nothing to upload")
    cfg = load_config()
    token = make_token(cfg)
    version, loc_id = localization(token, cfg["ASC_APP_ID"], args.locale)
    print(f"version {version}, {args.locale} ({loc_id}){' — dry run' if args.dry_run else ''}", flush=True)
    if args.screens:
        replace_screens(token, loc_id, args.display, sorted(args.screens), args.dry_run)
    if args.preview:
        token = make_token(cfg)          # a fresh token for the long video upload
        replace_preview(token, loc_id, args.display, args.preview, args.poster, args.dry_run)


if __name__ == "__main__":
    main()
