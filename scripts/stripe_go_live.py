#!/usr/bin/env python3
"""Switch Marracat's boosts and monthly boost budgets from Stripe test mode to live.

Run it ONLY after the owner has activated the Stripe account (business details
+ bank) and put the LIVE keys in ~/.config/marracat/stripe.env:

    STRIPE_SECRET_KEY=sk_live_...
    STRIPE_PUBLISHABLE_KEY=pk_live_...

Then:

    python3 scripts/stripe_go_live.py --dry-run   # checks only, changes nothing
    python3 scripts/stripe_go_live.py             # does it

What it does:
  1. Refuses unless the local key is sk_live_ and the account can take charges.
  2. Creates the LIVE webhook endpoint https://marracat.com/api/stripe/webhook
     with every event boosts.js / boost-budgets.js handle (or reuses one that
     already points there and updates its events). Stripe only reveals a
     webhook's signing secret when it's created, so an existing live endpoint
     needs its secret already in the local env file, or it's deleted and
     re-created.
  3. Writes STRIPE_WEBHOOK_SECRET into the local env (mode 600) and copies
     STRIPE_SECRET_KEY + STRIPE_WEBHOOK_SECRET into /etc/marracat/stripe.env on
     the droplet (same owner/mode as before), over ssh stdin, never argv.
  4. Restarts marracat-web and checks /api/boosts/status reports test: false.

The Stripe product for budgets and the billing-portal settings are created by
the server the first time they're needed (boost-budgets.js), so nothing else is
set up here. Secrets are never printed.
"""
import argparse
import base64
import json
import os
import pathlib
import subprocess
import sys
import urllib.parse
import urllib.request

LOCAL = pathlib.Path.home() / ".config/marracat/stripe.env"
HOST = "root@167.71.170.219"
REMOTE = "/etc/marracat/stripe.env"
URL = "https://marracat.com/api/stripe/webhook"
EVENTS = [
    "checkout.session.completed", "checkout.session.async_payment_succeeded",
    "invoice.paid", "invoice.payment_failed",
    "customer.subscription.updated", "customer.subscription.deleted",
]


def read_env(path):
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def write_env(path, values):
    text = "".join(f"{k}={v}\n" for k, v in values.items())
    tmp = path.with_suffix(".tmp")
    tmp.write_text(text)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def api(key, method, path, form=None):
    data = urllib.parse.urlencode(form, doseq=True).encode() if form else None
    req = urllib.request.Request(f"https://api.stripe.com/v1/{path}", data=data, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{key}:".encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        msg = json.load(e).get("error", {}).get("message", str(e))
        sys.exit(f"Stripe {method} {path}: {msg}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    env = read_env(LOCAL)
    key = env.get("STRIPE_SECRET_KEY", "")
    if not key.startswith("sk_live_"):
        sys.exit(f"{LOCAL} has no live secret key (sk_live_...). Put the live keys there first.")
    if not env.get("STRIPE_PUBLISHABLE_KEY", "").startswith("pk_live_"):
        print("note: STRIPE_PUBLISHABLE_KEY isn't pk_live_ (not used by the server; fine)")
    acct = api(key, "GET", "account")
    print(f"account {acct['id']}: charges_enabled={acct.get('charges_enabled')} payouts_enabled={acct.get('payouts_enabled')}")
    if not acct.get("charges_enabled"):
        sys.exit("The live account can't take charges yet: finish activation in the Stripe dashboard.")

    existing = [w for w in api(key, "GET", "webhook_endpoints?limit=100")["data"] if w["url"] == URL]
    if args.dry_run:
        print(f"dry run: would {'update' if existing else 'create'} the live webhook for {len(EVENTS)} events, "
              f"write the secret to {LOCAL} and {HOST}:{REMOTE}, and restart marracat-web")
        return
    secret = None
    if existing and env.get("STRIPE_WEBHOOK_SECRET", "").startswith("whsec_") and env.get("STRIPE_WEBHOOK_LIVE") == existing[0]["id"]:
        api(key, "POST", f"webhook_endpoints/{existing[0]['id']}", {"enabled_events[]": EVENTS})
        secret = env["STRIPE_WEBHOOK_SECRET"]
        endpoint = existing[0]["id"]
        print(f"updated live webhook {endpoint}")
    else:
        for w in existing:  # its secret is unknown here: replace it
            api(key, "DELETE", f"webhook_endpoints/{w['id']}")
            print(f"deleted live webhook {w['id']} (secret unknown)")
        w = api(key, "POST", "webhook_endpoints", {"url": URL, "enabled_events[]": EVENTS,
                                                   "description": "Marracat boosts + monthly boost budgets"})
        secret, endpoint = w["secret"], w["id"]
        print(f"created live webhook {endpoint}")

    env["STRIPE_WEBHOOK_SECRET"] = secret
    env["STRIPE_WEBHOOK_LIVE"] = endpoint
    write_env(LOCAL, env)
    print(f"wrote {LOCAL} (600)")

    # The droplet's file: same owner and mode as before, contents over stdin.
    remote_env = f"STRIPE_SECRET_KEY={key}\nSTRIPE_WEBHOOK_SECRET={secret}\n"
    script = (f"set -e; f={REMOTE}; t=$(mktemp); cat > $t; "
              f"if [ -f $f ]; then chown --reference=$f $t; chmod --reference=$f $t; else chmod 600 $t; fi; "
              f"mv $t $f; systemctl restart marracat-web")
    subprocess.run(["ssh", HOST, script], input=remote_env.encode(), check=True)
    print(f"updated {HOST}:{REMOTE} and restarted marracat-web")

    import time
    for _ in range(30):
        try:
            with urllib.request.urlopen("https://marracat.com/api/boosts/status", timeout=10) as r:
                status = json.load(r)
            if status.get("test") is False:
                print("live: /api/boosts/status reports test: false")
                return
        except Exception:
            pass
        time.sleep(4)
    sys.exit("marracat.com still reports test mode; check `journalctl -u marracat-web`.")


if __name__ == "__main__":
    main()
