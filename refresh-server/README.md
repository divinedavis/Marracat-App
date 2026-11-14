# Catalog refresh droplet (marracat-refresh)

Owner-approved 2026-10-12: the catalog refresh moved off the Mac onto its own
DigitalOcean droplet. The Mac keeps only what needs Apple silicon (nightly)
and the App Store downloads job (the ASC key stays off servers).

| | |
|---|---|
| Droplet | `marracat-refresh`, id 608458322, **104.236.122.134**, private 10.108.0.7, nyc3, `s-2vcpu-4gb` ($24/mo, no backups/volumes), Ubuntu 24.04, UTC |
| User | `marracat-refresh` (system, locked password), home `/var/lib/marracat-refresh` |
| Checkout | `/opt/marracat-refresh/Marracat` (the user's; GitHub key read-only, never commits) |
| Python / Node | `/opt/marracat-refresh/venv` (uv, Python 3.14, `requirements.txt`), `/usr/local/bin/node` (= marracat.com's) |
| Secrets | `/etc/marracat-refresh/` 0750 root:marracat-refresh: `refresh.env` (TYPESAFE_API_KEY), `smtp.json` (alert mailbox) — 0640, never in git. The Ed25519 catalog key is not here (2026-11-12): it is `/etc/marracat-signer/catalog-signing.key`, 0440 root:marracat-signer, and the refresh asks `marracat-signer.socket` for each signature (`signer/`), so the process that reads a thousand outside stores can't read the key |
| Units | `marracat-refresh.timer` -> `marracat-refresh.service` (-> `marracat-refresh-alert.service` on failure) |
| Log | `/var/log/marracat-refresh/refresh.log` (logrotate weekly, 8 kept) |

## What runs where

```
droplet, every 3 h (00/03/06/.../21:00 UTC)     Mac, nightly 01:30 New York
scripts/refresh_catalog.sh                     scripts/refresh_ml.sh (launchd com.marracat.catalog-refresh)
  take exchange/in (photo moves, roles cache)    pull_catalog.sh --state  <- exchange/out
  fetch stores, dedupe, brand fit (Jev)          photo roles (thumbnails + MobileCLIP)
  12 badges, category audit (ship gate)          photo category check + auto-moves
  attributes, colorways                          rsync photo_moves.json + photo_roles.json -> exchange/in
  photo roles from the cache only                embed_products --publish + publish_ml.sh (vectors, root@167.71)
  make_compact --no-binary
  publish_catalog.sh  (CATALOG_TARGET=receiver)
  publish_web_data.sh (data only, no code)
  catalog + state -> exchange/out
```

The Mac's outputs reach the next droplet run; if they lag (Mac asleep, job
off) nothing breaks: new products keep their title-based department and the
first photo as tile. The droplet emails if `exchange/in` is over 3 days old.

## Publishing to marracat.com (167.71.170.219) — least privilege

The droplet holds no root key for 167.71. Its key `~/.ssh/id_publish` logs in
as `marracat-pub` over the private network, and `authorized_keys` pins it:
`restrict,from="10.108.0.7",command="/usr/local/sbin/marracat-pub-ssh"`.
The forced command (`receiver/marracat-pub-ssh`) honours only:

- `put <name>` — stdin to `/var/lib/marracat-pub/incoming/<name>`, for the 9
  catalog files (`catalog{,-v2,-v3}.json{,.gz,.sig}`) and the 2 web data files
  (`catalog-slim.json`, `product-details.sqlite`); prints the md5
  and, since 2026-10-18, the catalog deltas (`catalog-v3-delta-<fp>.json{,.gz,.sig}`,
  `catalog-v3-manifest-<fp>.json.gz`, from catalog/catalog_delta.py)
- `catalog-swap` — `sudo marracat-catalog-swap`: checks, snapshot to
  /var/backups/marracat-catalog (8 kept), swap, served-bytes check, rollback;
  then any deltas go live through `marracat-catalog-deltas` into
  /var/www/marracat-catalog/catalog-v3/ (old deltas removed, 9 versions listed
  in manifests.txt). Optional: a publish without them still swaps.
- `web-data-release <generated_at> <product id>` — `sudo marracat-web-data-release`:
  a new release with the **current release's code** plus the new data, the same
  snapshot / restart / content checks / restore as web/deploy.sh
- `web-rollback <release id>` — restore that snapshot (the caller's public check failed)

Root steps move the uploads into a root-only directory first and refuse
anything that is not a plain, single-link file owned by marracat-pub. The
same lock (/run/lock/marracat-publish.lock) serialises them. Website **code**
ships only with `web/deploy.sh` from the Mac (as before, root).
Install/update the receiver from the Mac:
`refresh-server/receiver/install.sh <id_publish.pub> 10.108.0.7`.

The Mac's exchange key `~/.ssh/id_marracat_exchange` (used with Homebrew's rsync,
installed but `brew unlink`ed: on PATH it breaks Xcode's IPA export) is locked to
`restrict,command="/usr/bin/rrsync /var/lib/marracat-refresh/exchange"`.

## Run by hand

```bash
ssh root@104.236.122.134
systemctl start --no-block marracat-refresh       # a full run now (~1.5 h)
tail -f /var/log/marracat-refresh/refresh.log
systemctl list-timers marracat-refresh.timer       # next run
systemctl status marracat-refresh                  # last result
journalctl -u marracat-refresh -u marracat-refresh-alert -n 50
```

Don't start a Mac full refresh or a ship's publish while a droplet run is
publishing (both write the same files on 167.71).

Mac side: `scripts/pull_catalog.sh` (latest catalog to the Mac; ship.sh does
this itself), `launchctl kickstart gui/$(id -u)/com.marracat.catalog-refresh`
(the nightly ML job now). Rollbacks are unchanged: `scripts/rollback_catalog.sh`,
`scripts/rollback_web.sh` (root from the Mac).

**Fallback if the droplet is down:** on the Mac,
`scripts/refresh_catalog.sh && scripts/refresh_ml.sh` (publishes as root and
deploys with web/deploy.sh, the pre-2026-10-12 way).

## Generated state

The refresh rewrites tracked files (Jev caches such as `catalog/jev_brand_fit.json`,
`ingredients.json`, `jev_lists.json`, `photo_hashes.json`, the `*_report.md`).
The droplet never commits: `update_checkout.sh` (ExecStartPre) saves them,
resets to origin/main and merges them back (`merge_state.py`: JSON objects are
unioned, the droplet's entry winning a clash; other files keep the droplet's
copy unless upstream changed them). Each run copies them to `exchange/out/state`,
and the Mac's nightly `pull_catalog.sh --state` copies them into the Mac
checkout, so a commit from the Mac carries them. `catalog/photo_moves.json` is
the Mac's: it travels up, never down. A hand-deleted Jev verdict comes back
from the droplet's copy; delete it on the droplet too.

## Rebuild from nothing

1. Create the droplet (DO API, nyc3, `s-2vcpu-4gb`, ubuntu-24-04-x64, SSH key
   "macbook", VPC default) and add its IP to `~/.ssh/config`'s ControlMaster line.
2. `scp refresh-server/{provision.sh,requirements.txt} root@IP:/root/refresh-server/ && ssh root@IP bash /root/refresh-server/provision.sh`
   (makes the user, keys `id_github`/`id_publish`, venv, node; fails at the clone).
3. `gh repo deploy-key add <id_github.pub> -R divinedavis/Marracat` (read-only), run provision.sh again (clones, installs units).
4. Secrets into /etc/marracat-refresh (0640 root:marracat-refresh): `refresh.env` with
   `TYPESAFE_API_KEY=` from `~/.config/typesafe/api_key`; `smtp.json` = `~/.config/marracat/smtp.json`.
   The catalog key: copy `~/.config/marracat/catalog-signing.key` to `/etc/marracat-signer/catalog-signing.key`
   on the droplet (root only for now), then `refresh-server/signer/install.sh` from the Mac, which makes the
   signer's user, checks the key is the app's, and proves the refresh user can get a signature but not the key.
5. `refresh-server/receiver/install.sh <id_publish.pub> <private IP>` from the Mac.
6. Exchange key: append `restrict,command="/usr/bin/rrsync /var/lib/marracat-refresh/exchange" <~/.ssh/id_marracat_exchange.pub>`
   to `/var/lib/marracat-refresh/.ssh/authorized_keys`.
7. Seed the caches (one-time, saves a cold fetch): `rsync -a --exclude embeddings catalog/.cache/ root@IP:/opt/marracat-refresh/Marracat/catalog/.cache/`, then chown -R marracat-refresh.
8. `systemctl start --no-block marracat-refresh`, watch the log, `systemctl enable --now marracat-refresh.timer`.

## Database backups (2026-11-05)

marracat.com's storefront database (167.71, `/var/lib/marracat/marracat.sqlite`)
is copied here every night; DigitalOcean backups are off on every droplet.

- **167.71** `marracat-db-backup.timer` 07:15 UTC runs `/usr/local/sbin/marracat-db-backup`
  (web/backup/, installed by web/deploy.sh) as `marracat`: `sqlite3 .backup`,
  `integrity_check`, gzip, rsync over the VPC to `marracat-backup@10.108.0.7`.
  Key + pinned host key: `/etc/marracat/backup/` (700 marracat), made once with
  `ssh-keygen -t ed25519` and `ssh-keyscan -t ed25519 10.108.0.7` (check the
  fingerprint against this droplet's `/etc/ssh/ssh_host_ed25519_key.pub`).
- **Here** user `marracat-backup` (locked password) has one root-owned
  authorized_keys line: `from="10.108.0.3",restrict,command="/usr/bin/rrsync -wo -no-del /var/lib/marracat-backup/incoming"`.
  The sending key can write into `incoming/` and nothing else: no listing,
  reading, deleting or shell.
- **Here** `marracat-db-archive.timer` 08:30 UTC (refresh-server/backup/, root)
  checks each arrival (name, 512 MB cap, no symlinks, gzip, SQLite
  `integrity_check`), files it in `/var/backups/marracat-db` (700 root), keeps 30,
  and emails the owner (notify.py) when a copy fails its check or the newest is
  over 30 hours old.
- **Restore:** `gunzip -c /var/backups/marracat-db/<newest>.sqlite.gz > marracat.sqlite`,
  stop `marracat-web` on 167.71, put it at `/var/lib/marracat/marracat.sqlite`
  (owner marracat, 600, remove the old -wal/-shm), start it. Tested 2026-11-05:
  all 60 tables' row counts matched live.
