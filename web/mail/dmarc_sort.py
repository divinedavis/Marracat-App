#!/usr/bin/env python3
"""File hello@marracat.com mail into folders: DMARC reports, and each alias.

Aliases (owner, 2026-10-09) all deliver to the one hello@ mailbox; mail sent
to one lands in its folder (ALIAS_FOLDERS). creators@ stays in the INBOX on
purpose: the creator-reply reader on 104.236 (creator_mail_reader.py) only
scans the INBOX. The alias comes from X-Original-To (the envelope recipient,
so a Bcc is filed too), else To/Cc.

marracat.com's DMARC record (rua=mailto:hello@marracat.com, since 2026-10-07)
has Google, Yahoo, Microsoft and others mail a daily XML report to the shared
inbox. They are for machines; the owner asked (2026-10-08) for them to land in
their own folder. Private Email's server-side filters (ManageSieve, port 4190)
don't answer from outside, so a systemd timer runs this every 15 minutes and
MOVEs matching inbox messages over IMAP.

Logs in with the relay's mailbox credentials (/etc/marracat/relay.env:
RELAY_SMTP_USER / RELAY_SMTP_PASS — the same Private Email app password).
"""
from __future__ import annotations

import email
import email.header
import imaplib
import os
import re
import sys

HOST = os.environ.get("RELAY_SMTP_HOST", "mail.privateemail.com")
FOLDER = "DMARC Reports"
# Aggregate reports use this subject by RFC 7489 §7.2.1.1; every big receiver follows it.
SUBJECT_RE = re.compile(r"^\s*(\[[^\]]*\]\s*)?(fwd?:\s*)?report\s+domain:\s*\S+\s+submitter:", re.I)


ALIAS_FOLDERS = {
    "support": "Support", "orders": "Orders", "brands": "Brands", "press": "Press",
    "privacy": "Privacy", "security": "Security", "billing": "Billing", "dmarc": FOLDER,
}
ADDR_RE = re.compile(r"([a-z0-9._%+-]+)@marracat\.com\b", re.I)


def folder_for(original_to: str, to_cc: str) -> str | None:
    """The folder for mail sent to an alias, or None to leave it in the INBOX."""
    for text in (original_to, to_cc):
        for local in ADDR_RE.findall(text or ""):
            if local.lower() in ALIAS_FOLDERS:
                return ALIAS_FOLDERS[local.lower()]
        if original_to:
            return None  # the envelope said which address; To/Cc can't overrule it
    return None


def ensure(m, folder: str, boxes: list[str]) -> None:
    if not any(b.endswith(f'"{folder}"') or b.endswith(f" {folder}") for b in boxes):
        m.create(f'"{folder}"')
        m.subscribe(f'"{folder}"')
        boxes.append(f'"{folder}"')


def is_dmarc_report(subject: str) -> bool:
    return bool(SUBJECT_RE.search(subject or ""))


def decode(raw: str) -> str:
    return str(email.header.make_header(email.header.decode_header(raw or "")))


def main() -> int:
    user, password = os.environ.get("RELAY_SMTP_USER"), os.environ.get("RELAY_SMTP_PASS")
    if not user or not password:
        print("RELAY_SMTP_USER/RELAY_SMTP_PASS not set", file=sys.stderr)
        return 1
    m = imaplib.IMAP4_SSL(HOST, 993, timeout=60)
    m.login(user, password)
    _, raw_boxes = m.list()
    boxes = [b.decode() for b in raw_boxes or []]
    ensure(m, FOLDER, boxes)
    m.select("INBOX")
    _, data = m.uid("SEARCH", None, "ALL")
    moved = {}
    for uid in (data[0] or b"").split():
        _, hdr = m.uid("FETCH", uid, "(BODY.PEEK[HEADER.FIELDS (SUBJECT X-ORIGINAL-TO TO CC)])")
        if not hdr or not hdr[0]:
            continue
        msg = email.message_from_bytes(hdr[0][1])
        folder = FOLDER if is_dmarc_report(decode(msg.get("Subject", ""))) else folder_for(
            " ".join(msg.get_all("X-Original-To") or []),
            " ".join((msg.get_all("To") or []) + (msg.get_all("Cc") or [])))
        if folder:
            ensure(m, folder, boxes)
            typ, _ = m.uid("MOVE", uid, f'"{folder}"')
            if typ == "OK":
                moved[folder] = moved.get(folder, 0) + 1
    m.logout()
    for folder, n in sorted(moved.items()):
        print(f"moved {n} to {folder}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
