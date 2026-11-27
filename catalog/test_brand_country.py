"""catalog/brand_country.py: the country a brand is based in, for the
Country filter (owner, 2026-11-26: "Let's put a filter for the country the
company is founded")."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import brand_country as bc  # noqa: E402
from ships_from import REGIONS, region  # noqa: E402


def brand(**fields):
    return {"id": "b", "domain": "b.example", "currency": "USD", **fields}


class Evidence(unittest.TestCase):
    def test_a_scan_names_the_country(self):
        rows = {"b.example": {"country": "Nigeria"}}
        self.assertEqual(bc.decide(brand(ships_from="africa"), rows, {}), ("NG", "research"))

    def test_a_us_scan_names_a_state(self):
        self.assertEqual(bc.decide(brand(), {"b.example": {"state": "Georgia", "city": "Atlanta"}}, {}), ("US", "research"))
        # The US scan ticks "diaspora" for its own reasons; the brand is still in Denver.
        row = {"country": "United States", "state": "Colorado", "city": "Denver", "diaspora": True, "meta_country": None}
        self.assertEqual(bc.decide(brand(), {"b.example": row}, {}), ("US", "research"))

    def test_a_diaspora_brand_is_where_its_store_is_not_its_heritage(self):
        # Eloli: filed under Cameroon, run from Montreal.
        rows = {"b.example": {"country": "Cameroon", "diaspora": "True", "meta_country": "CA", "city": "Montreal"}}
        self.assertEqual(bc.decide(brand(ships_from="canada"), rows, {}), ("CA", "research"))

    def test_a_based_note_beats_the_heritage_country(self):
        self.assertEqual(bc.named("Zimbabwe (Netherlands-based)"), "NL")
        self.assertEqual(bc.named("Nigeria/Ghana"), "NG")
        self.assertEqual(bc.named("UK"), "GB")
        self.assertIsNone(bc.named("Caribbean (regional)"))

    def test_a_one_country_currency_names_it(self):
        self.assertEqual(bc.decide(brand(currency="NGN", ships_from="africa"), {}, {}), ("NG", "currency"))
        self.assertEqual(bc.decide(brand(currency="GBP", ships_from="europe"), {}, {}), ("GB", "currency"))

    def test_euros_and_dollars_name_no_country(self):
        self.assertEqual(bc.decide(brand(currency="EUR", ships_from="europe"), {}, {})[0], None)
        self.assertEqual(bc.decide(brand(), {}, {}), (None, "no evidence"))

    def test_the_registry_city_can_be_a_country_a_city_abroad_or_a_state(self):
        self.assertEqual(bc.from_place("Kenya"), "KE")
        self.assertEqual(bc.from_place("Lagos"), "NG")
        self.assertEqual(bc.from_place("Toronto, ON"), "CA")
        self.assertEqual(bc.from_place("GA"), "US")
        self.assertEqual(bc.from_place("Decatur, GA"), "US")
        self.assertIsNone(bc.from_place("Springfield"), "a bare US city says nothing by itself")
        self.assertIsNone(bc.from_place(""))

    def test_paris_texas_is_not_france(self):
        self.assertEqual(bc.from_place("Paris, TX"), "US")
        self.assertEqual(bc.from_place("Paris"), "FR")


class Referee(unittest.TestCase):
    """`ships_from` is research too; the store's billing country is not."""

    def test_the_stores_country_counts_when_it_matches_the_region(self):
        self.assertEqual(bc.decide(brand(city="Huntsville"), {}, {"b": "US"}), ("US", "store"))
        self.assertEqual(bc.decide(brand(currency="EUR", ships_from="europe"), {}, {"b": "FR"}), ("FR", "store"))

    def test_a_billing_address_abroad_never_moves_an_african_brand(self):
        # Ziva Lagos prices in naira and bills from the UK (ships_from.py).
        self.assertEqual(bc.decide(brand(currency="NGN", ships_from="africa"), {}, {"b": "GB"}), ("NG", "currency"))
        # KIZA: Kigali, billed from Estonia, priced in dollars.
        self.assertEqual(bc.decide(brand(city="Kigali", ships_from="africa"), {}, {"b": "EE"}), ("RW", "place"))
        country, why = bc.decide(brand(ships_from="africa"), {}, {"b": "EE"})
        self.assertIsNone(country)
        self.assertIn("store says EE", why)

    def test_two_sources_outvote_the_parcels_region(self):
        # Based in London, made and posted in Lagos.
        b = brand(currency="GBP", city="London", ships_from="africa")
        self.assertEqual(bc.decide(b, {}, {}), ("GB", "currency+place"))

    def test_an_unlabelled_brand_abroad_needs_the_store_to_agree(self):
        rows = {"b.example": {"country": "Canada"}}
        self.assertEqual(bc.decide(brand(), rows, {"b": "CA"}), ("CA", "research+store"))
        country, why = bc.decide(brand(), rows, {})
        self.assertIsNone(country)
        self.assertIn("research says CA", why)

    def test_one_source_against_the_region_is_left_for_a_person(self):
        rows = {"b.example": {"state": "Texas"}}
        country, why = bc.decide(brand(ships_from="africa"), rows, {"b": "US"})
        self.assertIsNone(country)
        self.assertIn("ships_from is africa", why)

    def test_a_hand_ruling_wins(self):
        bc.HAND["hand-test"] = "SN"
        try:
            self.assertEqual(bc.decide(brand(id="hand-test", currency="GBP", ships_from="europe"), {}, {}), ("SN", "hand"))
        finally:
            del bc.HAND["hand-test"]


class Backfill(unittest.TestCase):
    def test_it_sets_and_clears(self):
        brands = [brand(id="a", currency="KES", ships_from="africa"), brand(id="c", country="FR", country_source="store")]
        done, unresolved = bc.backfill(brands, {}, {})
        self.assertEqual((brands[0]["country"], brands[0]["country_source"]), ("KE", "currency"))
        self.assertNotIn("country", brands[1])
        self.assertNotIn("country_source", brands[1])
        self.assertEqual((done, unresolved), (1, [("c", "no evidence")]))

    def test_fetch_reads_only_shopify_stores_not_on_file(self):
        asked = []

        def get(domain):
            asked.append(domain)
            return {"country": "us"} if domain == "new.example" else {"country": "nowhere"}
        brands = [{"id": "old", "domain": "old.example"}, {"id": "new", "domain": "new.example"},
                  {"id": "odd", "domain": "odd.example"}, {"id": "woo", "domain": "woo.example", "platform": "woocommerce", "shopify": False}]
        stores = {"old": "GB"}
        self.assertEqual(bc.fetch(brands, stores, pause=0, get=get), 1)
        self.assertEqual(asked, ["new.example", "odd.example"])
        self.assertEqual(stores, {"old": "GB", "new": "US"})


class Registry(unittest.TestCase):
    """The real brands.json."""

    def setUp(self):
        self.brands = json.loads(bc.BRANDS.read_text())

    def test_every_country_is_a_code_with_its_evidence(self):
        for b in self.brands:
            if "country" in b:
                self.assertRegex(b["country"], r"^[A-Z]{2}$", b["id"])
                self.assertTrue(b.get("country_source"), b["id"])

    def test_the_registry_is_what_the_rules_give(self):
        stores = json.loads(bc.STORES.read_text())
        rows = bc.research_rows()
        for b in self.brands:
            self.assertEqual(b.get("country"), bc.decide(b, rows, stores)[0], b["id"])

    def test_most_brands_have_a_country(self):
        have = sum(1 for b in self.brands if b.get("country"))
        self.assertGreater(have / len(self.brands), 0.9, f"{have} of {len(self.brands)}")

    def test_a_hand_ruling_names_a_real_brand(self):
        ids = {b["id"] for b in self.brands}
        self.assertEqual(sorted(set(bc.HAND) - ids), [])
        self.assertIn(None, {region("US")})
        self.assertTrue(all(region(c) in (None, *REGIONS) for c in bc.HAND.values()))


if __name__ == "__main__":
    unittest.main()
