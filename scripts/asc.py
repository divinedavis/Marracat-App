"""Shared App Store Connect API helpers for the Marracat scripts.

Reads scripts/asc-config.env (gitignored). Run scripts with the project venv:
    ~/.venvs/marracat/bin/python scripts/<script>.py
"""
from __future__ import annotations

import os
import pathlib
import re
import time

import jwt
import requests

CONFIG_PATH = pathlib.Path(__file__).resolve().parent / "asc-config.env"
API_BASE = "https://api.appstoreconnect.apple.com/v1"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        raise SystemExit(f"missing {CONFIG_PATH} — copy asc-config.env.example")
    cfg: dict = {}
    for line in CONFIG_PATH.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        k, _, v = s.partition("=")
        cfg[k.strip()] = os.path.expandvars(v.strip().strip('"').strip("'"))
    return cfg


def write_config_value(key: str, value: str) -> None:
    text = CONFIG_PATH.read_text()
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    # The env file is `source`d by ship.sh — quote anything with spaces.
    if any(c in value for c in ' \t"'):
        value = '"' + value.replace('"', '\\"') + '"'
    line = f"{key}={value}"
    text = pattern.sub(line, text) if pattern.search(text) else text.rstrip() + f"\n{line}\n"
    CONFIG_PATH.write_text(text)


def make_token(cfg: dict) -> str:
    private_key = pathlib.Path(cfg["ASC_KEY_PATH"]).expanduser().read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": cfg["ASC_ISSUER_ID"], "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": cfg["ASC_KEY_ID"], "typ": "JWT"},
    )


def api(token: str, method: str, path: str, params=None, body=None, ok_statuses=()) -> tuple[int, dict]:
    # GETs retry on dropped connections (ASC resets TLS handshakes now and then,
    # which once killed a processing poll). Writes don't: replaying a POST could
    # create a resource twice, so they still fail loudly.
    attempts = 3 if method == "GET" else 1
    for attempt in range(attempts):
        try:
            r = requests.request(
                method,
                f"{API_BASE}{path}",
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                params=params or {},
                json=body,
                timeout=30,
            )
            break
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
            if attempt == attempts - 1:
                raise
            time.sleep(5 * (attempt + 1))
    if r.status_code >= 400 and r.status_code not in ok_statuses:
        raise SystemExit(f"{method} {path} -> {r.status_code}\n{r.text}")
    return r.status_code, (r.json() if r.text else {})
