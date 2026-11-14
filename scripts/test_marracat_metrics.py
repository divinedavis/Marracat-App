"""The dashboard's Find A Crib-style numbers from the visits table
(web/metrics/marracat_metrics.py; owner, 2026-10-04)."""
import datetime, sqlite3, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web/metrics"))
import marracat_metrics as mm

D = datetime.date(2026, 10, 31)


def db_with(visits, users=()):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE visits(day,visitor,platform,build,channel,ref_host,src,first,user_id)")
    db.execute("CREATE TABLE users(id,name,email,created_at)")
    for v in visits:
        db.execute("INSERT INTO visits VALUES(?,?,?,?,?,?,?,?,?)", v)
    for u in users:
        db.execute("INSERT INTO users VALUES(?,?,?,?)", u)
    return db


def day(n):
    return (D - datetime.timedelta(days=n)).isoformat()


def test_retention_actives_and_sources():
    db = db_with([
        # a: first visit 10 days ago from TikTok, back the next day -> D1 and D7
        (day(10), "a", "web", None, None, "tiktok.com", "", 1, None), (day(9), "a", "web", None, None, None, None, 0, None),
        # b: first visit 40 days ago from Google, never back
        (day(40), "b", "web", None, None, "google.com", "", 1, None),
        # c: App Store app today
        (day(0), "c", "ios", "101", "appstore", None, None, 1, None),
        # TestFlight and the owner don't count
        (day(0), "t", "ios", "101", "testflight", None, None, 1, None),
        (day(2), "o", "web", None, None, None, None, 1, "apple:owner"),
    ], users=[("apple:owner", "Owner", "divinejdavis@gmail.com", "2026-09-01 00:00:00")])
    vis = mm.visit_rows(db)
    assert set(vis) == {"a", "b", "c"}
    ret = mm.retention(vis, D)
    assert ret["d1"] == {"cohort": 2, "returned": 1, "rate": 0.5}
    assert ret["d30"]["cohort"] == 1 and ret["d30"]["returned"] == 0  # only b is 30+ days old
    eng = mm.engagement(vis, D)
    assert (eng["mau"], eng["mau_prior"], eng["wau"], eng["app_actives_30d"]) == (2, 1, 1, 1)
    src = mm.sources(vis, D)
    assert (src["social"], src["app"], src["search"], src["new"]) == (1, 1, 0, 2)  # b is older than 30 days


def test_returning_and_daily_series():
    db = db_with([(day(1), "a", "web", None, None, None, None, 1, None), (day(0), "a", "web", None, None, None, None, 0, None),
                  (day(0), "b", "web", None, None, None, None, 1, None)],
                 users=[("google:1", "S", "s@example.com", f"{day(0)} 15:00:00")])
    vis = mm.visit_rows(db)
    assert mm.visits_range(vis, "today", D) == {"visitors": 2, "returning": 1, "web": 2, "app": 0}
    series = mm.daily_series(vis, db, D, D - datetime.timedelta(days=1))
    assert [s["visitors"] for s in series] == [1, 2]
    assert series[-1]["signups"] == 1
    # The chart's split lines: web / app and returning (seen on an earlier day).
    assert [(s["web"], s["app"], s["returning"]) for s in series] == [(1, 0, 0), (2, 0, 1)]


def test_source_kinds():
    assert mm._source("web", "", "") == "direct"
    assert mm._source("web", "", "tiktok-bio") == "tagged"
    assert mm._source("web", "l.instagram.com", "") == "social"
    assert mm._source("web", "duckduckgo.com", "") == "search"
    assert mm._source("web", "blog.example.com", "") == "referral"
    assert mm._source("ios", "", "") == "app"


def test_a_bot_farm_is_not_visitors(tmp_path=None):
    """2026-10-24: Leaseweb opened one page from each of ~47 addresses in one
    block with an old Linux Chrome; a block with FARM_IPS+ addresses and one
    browser on a day isn't visitors. A household on one address still counts."""
    import tempfile
    d = Path(tempfile.mkdtemp())
    ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"
    home = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    line = ('marracat.com {ip} - - [24/Oct/2026:15:00:00 +0000] "GET {path} HTTP/1.1" {st} 100 '
            '"https://marracat.com/" "{ua}"\n')
    rows = [line.format(ip=f"152.163.233.{i}", path="/api/catalog", st=200, ua=ua) for i in range(1, mm.FARM_IPS + 2)]
    rows += [line.format(ip=f"152.163.233.{i}", path="/api/products/x", st=200, ua=ua) for i in range(1, 4)]
    rows += [line.format(ip="71.190.10.4", path="/api/catalog", st=200, ua=home),
             line.format(ip="71.190.10.4", path="/api/products/y", st=200, ua=home)]
    (d / "site.log").write_text("".join(rows))
    mm.SHARED_LOG, mm.SITE_LOG = str(d / "none.log"), str(d / "site.log")
    _app, web, products = mm.collect_log(set(), set())
    assert [w[1] for w in web] == ["71.190.10.4"], web
    assert [p[1] for p in products] == ["71.190.10.4"], products


def test_search_models_splits_devices_by_build():
    t = D - datetime.timedelta(days=1)
    app = [
        (D, "1.1.1.1", "Marracat/166", 166, True, False),       # S0 build
        (D, "1.1.1.1", "Marracat/166", 166, False, False),      # same device, same day
        (D, "2.2.2.2", "Marracat/167", 167, True, True),        # S4, TestFlight counts
        (D, "3.3.3.3", "Marracat/167", 167, True, "apple"),     # App Review doesn't
        (t, "4.4.4.4", "Marracat/160", 160, True, False),
        (D - datetime.timedelta(days=40), "5.5.5.5", "Marracat/150", 150, True, False),  # too old
    ]
    r = mm.search_models(app, D)
    assert len(r["days"]) == 30 and r["days"][-1] == {"date": D.isoformat(), "s0": 1, "s4": 1}
    assert r["days"][-2]["s0"] == 1
    assert r["last7"] == {"s0": 2, "s4": 1, "s0_share": round(2 / 3, 4)}


def test_investor_windows_end_on_their_tiles():
    """The investor card's Period (owner, 2026-11-11): every window's lines
    end on its tile's number, the line before ends on the "was", all time
    has no window before it, and checkouts count as buyers by window."""
    db = db_with([
        (day(10), "a", "web", None, None, "tiktok.com", "", 1, None), (day(9), "a", "web", None, None, None, None, 0, None),
        (day(40), "b", "web", None, None, "google.com", "", 1, None),
        (day(0), "c", "ios", "101", "appstore", None, None, 1, None),
        (day(20), "d", "web", None, None, None, None, 1, None), (day(3), "d", "web", None, None, None, None, 0, None),
    ], users=[("google:1", "S", "s@example.com", f"{day(5)} 15:00:00"),
              ("google:2", "T", "t@example.com", f"{day(35)} 15:00:00")])
    db.execute("CREATE TABLE mobile_profiles(user_id, data)")
    when = datetime.datetime.combine(D - datetime.timedelta(days=4), datetime.time(12), mm.LOCAL).timestamp() - mm.APPLE_EPOCH
    db.execute("INSERT INTO mobile_profiles VALUES(?,?)",
               ("google:1", '{"checkouts":[{"date":%f,"total":25.5,"currency":"USD"}]}' % when))
    vis = mm.visit_rows(db)
    inv = mm.investor(vis, db, D, D - datetime.timedelta(days=40))
    w = inv["windows"]["30"]
    S = w["series"]
    assert len(S["actives"]["cur"]) == 30 and w["start"] == day(29)
    assert (w["actives"], w["actives_prior"]) == (3, 1)          # a, c, d now; b before
    assert S["actives"]["cur"][-1] == w["actives"] and S["actives"]["prev"][-1] == w["actives_prior"]
    assert (w["new_accounts"], w["new_accounts_prior"], w["accounts_all"]) == (1, 1, 2)
    assert (w["app_actives"], w["buyers"], w["gmv_usd"]) == (1, 1, 25.5)
    assert S["buyers"]["cur"][-1] == 0.5                         # 1 buyer of 2 accounts
    assert w["sources"]["new"] == 3 and w["sources"]["social"] == 1
    assert S["organic"]["cur"][-1] == w["sources"]["organic_share"]
    # Return rates: arrivals over the 30 days that ended 1 day ago.
    assert w["retention"]["d1"]["cohort"] == 2 and S["d1"]["cur"][-1] == 0.5    # a back next day, d not
    assert S["wau"]["cur"][-1] == inv["wau"] == 2              # c today, d 3 days ago
    assert S["stickiness"]["cur"][-1] == inv["stickiness"]
    eng = mm.engagement(vis, D)
    assert (inv["wau"], inv["stickiness"]) == (eng["wau"], eng["stickiness"])
    al = inv["windows"]["all"]
    assert al["all_time"] and al["series"]["actives"]["prev"] is None and al["actives"] == 4
    assert len(inv["windows"]["14"]["series"]["wau"]["cur"]) == 14
    # All time reaches back to an account older than the visitor log.
    early = mm.investor(vis, db, D, D - datetime.timedelta(days=20))["windows"]["all"]
    assert early["start"] == day(35) and early["new_accounts"] == early["accounts_all"] == 2
