#!/usr/bin/env python3
"""Is the catalog the refresh droplet handed over recent enough to bundle
as it is? (owner, 2026-11-09: "add all the recommendations")

The droplet rebuilds, badges, audits and publishes the catalog every 3 hours
(scripts/refresh_catalog.sh). ship.sh used to pull that catalog and then do
the badges, the audit and the publish all over again on the Mac, ~19 of a
43-minute nightly ship. Now it trusts a fresh one and keeps the Mac's own
path as the backstop for a stale one: the droplet was stuck 2026-10-22..31
and the ship's publish was all that kept the catalog moving.

Fresh is judged by the catalog's own `generated_at` (when the droplet built
it), never by when this Mac downloaded the file. A catalog without a
readable stamp is not fresh.

    catalog_freshness.py FILE [--max-hours 6]     exit 0 fresh, 1 stale, 2 unknown
    catalog_freshness.py FILE --not-older-than URL
                                                  exit 0 when FILE is at least as
                                                  new as the catalog URL serves,
                                                  1 when older, 2 unknown
"""
import argparse
import datetime
import re
import sys
import urllib.request

STAMP = re.compile(rb'"generated_?[aA]t"\s*:\s*"([^"]+)"')
HEAD = 65536  # the stamp is the first key; never load the 400 MB file for it


def parse(stamp):
    """An ISO-8601 UTC stamp -> aware datetime, or None."""
    if isinstance(stamp, bytes):
        stamp = stamp.decode("ascii", "replace")
    try:
        when = datetime.datetime.fromisoformat(stamp.strip().replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=datetime.timezone.utc)
    return when


def stamp_in(head):
    m = STAMP.search(head)
    return parse(m.group(1)) if m else None


def file_stamp(path):
    try:
        with open(path, "rb") as f:
            return stamp_in(f.read(HEAD))
    except OSError:
        return None


def url_stamp(url, timeout=20):
    if not url.startswith("https://"):
        return None
    req = urllib.request.Request(url, headers={"Range": f"bytes=0-{HEAD - 1}", "User-Agent": "marracat-ship"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (https only, checked above)
            return stamp_in(r.read(HEAD))
    except Exception:  # noqa: BLE001 (any network trouble = unknown)
        return None


def verdict(when, now, max_hours):
    """'fresh' | 'stale' | 'unknown' for a catalog stamped `when`."""
    if when is None:
        return "unknown"
    age = (now - when).total_seconds() / 3600
    # A stamp from the future is a clock or a file gone wrong, not a fresh catalog.
    if age < -0.25:
        return "unknown"
    return "fresh" if age <= max_hours else "stale"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--max-hours", type=float, default=6.0)
    ap.add_argument("--not-older-than", metavar="URL")
    args = ap.parse_args(argv)
    mine = file_stamp(args.file)
    if args.not_older_than:
        live = url_stamp(args.not_older_than)
        if mine is None or live is None:
            print(f"catalog: can't compare with the live one (this Mac's: {mine}, live: {live})")
            return 2
        print(f"catalog: this Mac's is from {mine:%F %T}Z, the live one from {live:%F %T}Z")
        return 0 if mine >= live else 1
    now = datetime.datetime.now(datetime.timezone.utc)
    what = verdict(mine, now, args.max_hours)
    if what == "unknown":
        print(f"catalog: no usable generated_at in {args.file}; not treating it as fresh")
        return 2
    age = (now - mine).total_seconds() / 3600
    print(f"catalog: built by the droplet {age:.1f} h ago ({mine:%F %T}Z); {what} (limit {args.max_hours:g} h)")
    return 0 if what == "fresh" else 1


if __name__ == "__main__":
    sys.exit(main())
