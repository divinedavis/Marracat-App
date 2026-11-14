"""A store whose feed answers 200 with no products keeps last run's products
(2026-10-17: Maya Njie, Afrocenchix, Tawana Simone and Tiannia Barnes, all
with stock, were dropped as "nothing for sale")."""
from unittest import mock

import build_catalog as bc


def run(answers):
    calls = iter(answers)
    bc.FETCH_TROUBLE.clear()
    with mock.patch.object(bc, "fetch_json", lambda url: {"products": next(calls)}), \
         mock.patch.object(bc, "DELAY", 0), mock.patch.object(bc, "EMPTY_RETRY_WAIT", 0):
        return bc.fetch_store("shop.example")


def test_an_empty_first_page_is_asked_again():
    assert run([[], [{"id": 1}]]) == [{"id": 1}]
    assert "shop.example" not in bc.FETCH_TROUBLE


def test_empty_twice_counts_as_a_temporary_failure():
    assert run([[], []]) == []
    assert bc.FETCH_TROUBLE["shop.example"] is True


def test_a_full_store_is_not_asked_twice():
    assert run([[{"id": 1}]]) == [{"id": 1}]
    assert "shop.example" not in bc.FETCH_TROUBLE


def test_a_product_shifted_onto_the_next_page_is_kept_once():
    first = [{"id": i} for i in range(bc.PAGE_SIZE)]
    assert run([first, [{"id": bc.PAGE_SIZE - 1}, {"id": "new"}]]) == first + [{"id": "new"}]


def test_the_written_catalog_has_each_id_once():
    kept, dropped = bc.unique_by_id([{"id": "a", "n": 1}, {"id": "b"}, {"id": "a", "n": 2}])
    assert kept == [{"id": "a", "n": 1}, {"id": "b"}] and dropped == 1
