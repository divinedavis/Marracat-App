"""Dollar rates for non-dollar brands (catalog/fx.py; owner, 2026-10-08)."""
import fx


def test_live_rates_win_when_sane_and_bad_answers_keep_the_fallback():
    def fetch(url):
        if "frankfurter" in url:
            return {"rates": {"GBP": 0.8, "EUR": 0.9, "SEK": 10.0, "ZAR": 16.0}}
        return {"rates": {"NGN": 1300.0, "KES": 999999.0, "GHS": 12.0, "GBP": 5.0}}
    r = fx.usd_rates(fetch)
    assert r["GBP"] == 1.25, "the ECB pound, not the open endpoint's absurd one"
    assert r["NGN"] == round(1 / 1300, 6)
    assert r["KES"] == round(1 / fx.FALLBACK_PER_USD["KES"], 6), "an absurd shilling keeps the fallback"


def test_offline_build_uses_the_fallback():
    def fetch(url):
        raise OSError("offline")
    r = fx.usd_rates(fetch)
    assert set(r) == set(fx.FALLBACK_PER_USD)
    assert 0 < r["NGN"] < 0.01


def test_apply_stamps_non_dollar_brands_only():
    brands = [{"id": "a", "currency": "NGN"}, {"id": "b"}, {"id": "c", "currency": "USD", "usd_rate": 9},
              {"id": "d", "currency": "XYZ"}]
    fx.apply(brands, {"NGN": 0.00075})
    assert brands[0]["usd_rate"] == 0.00075
    assert "usd_rate" not in brands[1] and "usd_rate" not in brands[2], "dollar brands carry no rate"
    assert "usd_rate" not in brands[3], "an unknown currency is left alone, not guessed"


def test_caribbean_currencies_have_a_rate_before_any_answer():
    """The Canada and Caribbean scan's brands (owner, 2026-10-22)."""
    def fetch(url):
        raise OSError("offline")
    r = fx.usd_rates(fetch)
    assert r["BBD"] == 0.5 and r["BSD"] == 1.0, "pegged to the dollar"
    assert 0.006 < r["JMD"] < 0.007 and 0.37 < r["XCD"] < 0.371


def test_dirham_has_a_rate_before_any_answer():
    """A Dubai-based brand from the 2026-10-23 import prices in dirhams."""
    def fetch(url):
        raise OSError("offline")
    assert 0.272 < fx.usd_rates(fetch)["AED"] < 0.273, "pegged at 3.6725 to the dollar"


def test_swiss_franc_from_the_ecb():
    """Sahara Accessories, Switzerland (owner, 2026-11-11)."""
    def fetch(url):
        if "frankfurter" in url:
            assert "CHF" in url
            return {"rates": {"CHF": 0.83}}
        return {"rates": {"CHF": 0.5}}  # the open source never overrides an ECB currency
    rate = fx.usd_rates(fetch)["CHF"]
    assert 1.20 < rate < 1.21
    assert 1.2 < fx.usd_rates(lambda url: {})["CHF"] < 1.21, "fallback when neither answers"
