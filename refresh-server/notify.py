#!/usr/bin/env python3
"""Email the owner about the catalog refresh droplet (failure alerts).

    notify.py "<subject>" "<body>"            # from scripts/refresh_catalog.sh
    notify.py --failed-unit marracat-refresh  # the unit's OnFailure: last 60 log lines

SMTP login from MARRACAT_SMTP (default /etc/marracat-refresh/smtp.json, the
same shape as the Mac's ~/.config/marracat/smtp.json: host, port, user,
password), sent over implicit TLS (465). Recipient: MARRACAT_OWNER_EMAIL.
At most one email per subject per hour (a stamp in MARRACAT_ALERT_STATE), so
a flapping run can't flood the inbox.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import smtplib
import ssl
import subprocess
import sys
import time
from email.message import EmailMessage

SMTP_FILE = pathlib.Path(os.environ.get("MARRACAT_SMTP", "/etc/marracat-refresh/smtp.json"))
STATE = pathlib.Path(os.environ.get("MARRACAT_ALERT_STATE", "/var/lib/marracat-refresh/alerts"))
LOG = pathlib.Path(os.environ.get("MARRACAT_REFRESH_LOG", "/var/log/marracat-refresh/refresh.log"))
TO = os.environ.get("MARRACAT_OWNER_EMAIL", "divinejdavis@gmail.com")
QUIET_SECONDS = 3600


def build(subject: str, body: str, cfg: dict) -> EmailMessage:
    m = EmailMessage()
    m["From"] = f"Marracat refresh <{cfg['user']}>"
    m["To"] = TO
    m["Subject"] = subject[:200]
    m.set_content(body)
    return m


def recently_sent(subject: str, now: float | None = None) -> bool:
    """True when the same subject went out within QUIET_SECONDS; records it otherwise."""
    now = time.time() if now is None else now
    STATE.mkdir(parents=True, exist_ok=True)
    stamp = STATE / hashlib.sha1(subject.encode()).hexdigest()[:16]
    if stamp.exists() and now - stamp.stat().st_mtime < QUIET_SECONDS:
        return True
    stamp.touch()
    os.utime(stamp, (now, now))
    return False


def log_tail(n: int = 60) -> str:
    try:
        return "\n".join(LOG.read_text(errors="replace").splitlines()[-n:])
    except OSError as e:
        return f"(no log: {e})"


def send(subject: str, body: str) -> None:
    if recently_sent(subject):
        print(f"alert suppressed (sent within the hour): {subject}")
        return
    cfg = json.loads(SMTP_FILE.read_text())
    with smtplib.SMTP_SSL(cfg["host"], int(cfg.get("port", 465)), context=ssl.create_default_context(), timeout=30) as s:
        s.login(cfg["user"], cfg["password"])
        s.send_message(build(subject, body, cfg))
    print(f"alert sent: {subject}")


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--failed-unit":
        host = subprocess.run(["hostname"], capture_output=True, text=True).stdout.strip()
        send(f"Marracat catalog refresh FAILED on {host}",
             f"{argv[1]} failed. Last lines of {LOG}:\n\n{log_tail()}\n\n"
             f"More: ssh root@104.236.122.134 journalctl -u {argv[1]} -n 200\n"
             "The app and marracat.com keep serving the last good catalog.")
        return 0
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    send(argv[0], argv[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
