#!/usr/bin/env python3
"""Pull Marracat's App Store downloads into appstore.json for the owner
dashboard (owner, 2026-10-04: the Marracat tab should match Find A Crib's).

Ported from dhcr-map/ios/scripts/asc_downloads.py: reads the App Store Connect
analytics reports of the ONGOING request created 2026-10-04 (REQUEST_ID):
"App Downloads Standard" (first-time downloads, redownloads) and "App Store
Discovery and Engagement Standard" (impressions, product page views). Apple
makes one instance a day, one to two days behind; each instance also revises
the day before, so the newest instance wins for every date.

    ~/.venvs/marracat/bin/python scripts/asc_downloads.py            # writes scripts/appstore.json
    ~/.venvs/marracat/bin/python scripts/asc_downloads.py --deploy   # ...and copies it to the server

Runs from the Mac, where the ASC key lives (launchd com.marracat.asc-downloads).
The server's metrics job (web/metrics/marracat_metrics.py) reads the copy.
"""
from __future__ import annotations

import csv, gzip, io, json, subprocess, sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc  # noqa: E402

REQUEST_ID = "14d4a32d-f875-4f2c-8a90-a608d4a593fa"
REPORTS = {"downloads": "App Downloads Standard", "discovery": "App Store Discovery and Engagement Standard"}
OUT = Path(__file__).resolve().parent / "appstore.json"
DEPLOY = "root@167.71.170.219:/var/lib/marracat-metrics/appstore.json"
DAYS = 90


def get_all(token, url, params=None):
    rows = []
    while url:
        r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, params=params, timeout=60)
        params = None
        r.raise_for_status()
        j = r.json()
        rows += j["data"]
        url = j.get("links", {}).get("next")
    return rows


def read_tsv(url):
    raw = requests.get(url, timeout=120).content
    try:
        raw = gzip.decompress(raw)
    except OSError:
        pass
    return list(csv.DictReader(io.StringIO(raw.decode("utf-8", "replace")), delimiter="\t"))


def pull(token):
    reports = {d["attributes"]["name"]: d["id"]
               for d in get_all(token, f"{asc.API_BASE}/analyticsReportRequests/{REQUEST_ID}/reports", {"limit": 200})}
    since = (datetime.now(timezone.utc) - timedelta(days=DAYS)).date().isoformat()
    daily, latest = defaultdict(lambda: defaultdict(int)), None
    for key, name in REPORTS.items():
        rid = reports.get(name)
        if not rid:
            continue
        inst = [i for i in get_all(token, f"{asc.API_BASE}/analyticsReports/{rid}/instances",
                                   {"limit": 200, "filter[granularity]": "DAILY"})
                if i["attributes"]["processingDate"] >= since]
        by_date = {}
        for i in sorted(inst, key=lambda i: i["attributes"]["processingDate"]):
            fresh = defaultdict(lambda: defaultdict(int))
            for seg in get_all(token, f"{asc.API_BASE}/analyticsReportInstances/{i['id']}/segments"):
                for row in read_tsv(seg["attributes"]["url"]):
                    d = row.get("Date") or row.get("date")
                    if not d:
                        continue
                    latest = max(latest or d, d)
                    n = int(float(row.get("Counts") or 0))
                    if key == "downloads":
                        kind = (row.get("Download Type") or "").lower()
                        if "first" in kind:
                            fresh[d]["downloads_first"] += n
                        elif "redownload" in kind:
                            fresh[d]["redownloads"] += n
                    else:
                        ev = (row.get("Event") or "").lower()
                        if "impression" in ev:
                            fresh[d]["impressions"] += n
                        elif "page view" in ev:
                            fresh[d]["page_views"] += n
            by_date.update(fresh)  # a later instance's revision replaces an earlier one
        for d, vals in by_date.items():
            for k, v in vals.items():
                daily[d][k] += v
    return daily, latest


def summary(daily, latest, n):
    if not latest:
        return {}
    end = datetime.fromisoformat(latest).date()
    s = defaultdict(int)
    for d, v in daily.items():
        if end - timedelta(days=n - 1) <= datetime.fromisoformat(d).date() <= end:
            for k, x in v.items():
                s[k] += x
    s = dict(s)
    s["conv_page_view"] = round(100 * s.get("downloads_first", 0) / s["page_views"], 1) if s.get("page_views") else None
    return s


def main():
    cfg = asc.load_config()
    token = asc.make_token(cfg)
    try:
        daily, latest = pull(token)
        payload = {"as_of": latest, "days": {d: dict(v) for d, v in sorted(daily.items())},
                   "d7": summary(daily, latest, 7), "d28": summary(daily, latest, 28),
                   "note": None if latest else "Apple has not produced the first daily report yet (request made 2026-10-04)."}
    except Exception as e:  # noqa: BLE001 — the dashboard shows the reason instead of stale numbers
        payload = {"as_of": None, "days": {}, "d7": {}, "d28": {}, "note": f"pull failed: {e}"[:300]}
    payload["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    OUT.write_text(json.dumps(payload, indent=1) + "\n")
    print("wrote", OUT, "as_of", payload["as_of"], payload.get("note") or "")
    if "--deploy" in sys.argv:
        p = subprocess.run(["scp", "-q", "-o", "BatchMode=yes", str(OUT), DEPLOY], capture_output=True, text=True)
        print("deployed" if p.returncode == 0 else "scp failed: " + p.stderr[:200])


if __name__ == "__main__":
    main()
