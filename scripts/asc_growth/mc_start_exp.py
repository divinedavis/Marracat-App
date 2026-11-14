"""Start the "Lead with deals" product page A/B test once App Review approves it.

Apple refuses PATCH started:true until review is done (409 "Can't start
experiment, not in a draft state" while WAITING_FOR_REVIEW), so this polls the
experiment every --every seconds (up to --hours) and starts it the moment its
state is ACCEPTED/APPROVED. It exits without starting on REJECTED. The owner
decided 2026-10-11 that the test is started as soon as it is approved.

    PYTHONPATH=scripts/asc_growth:~/projects/dhcr-map/ios/scripts \\
      ~/.venvs/dhcr-map/bin/python scripts/asc_growth/mc_start_exp.py [--once]
"""
import argparse, sys, time, requests
from datetime import datetime
from mc_growth import call, API
from asc_creative_assets import _headers

X = "ba7f2f9b-1805-4f91-897c-c21737eea64d"
READY = {"ACCEPTED", "APPROVED"}
DONE = {"REJECTED", "COMPLETED", "STOPPED"}


def log(*a):
    print(datetime.now().isoformat(timespec="seconds"), *a, flush=True)


def state():
    return call("GET", f"/v2/appStoreVersionExperiments/{X}")["data"]["attributes"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--every", type=int, default=900)
    ap.add_argument("--hours", type=float, default=96)
    a = ap.parse_args()
    deadline = time.time() + a.hours * 3600
    while True:
        try:
            s = state()
        except (Exception, SystemExit) as e:  # call() sys.exits on HTTP errors: keep polling
            log("poll failed:", e)
            s = {}
        st = s.get("state")
        log("state", st, "start", s.get("startDate"), "traffic", s.get("trafficProportion"))
        if s.get("startDate") or st == "IN_PROGRESS" or st in DONE:
            return 0 if st != "REJECTED" else 1
        if st in READY:
            r = requests.patch(API + f"/v2/appStoreVersionExperiments/{X}", headers=_headers(), timeout=60,
                               json={"data": {"type": "appStoreVersionExperiments", "id": X,
                                              "attributes": {"started": True}}})
            log("start ->", r.status_code, r.text[:600])
            if r.ok:
                log("now", state())
                return 0
        if a.once or time.time() > deadline:
            return 2
        time.sleep(a.every)


if __name__ == "__main__":
    sys.exit(main())
