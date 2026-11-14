"""Best-seller pages are fetched with the storefront TLS context (X25519
only): the refresh droplet's OpenSSL 3.5 default drew a 429 from every
Shopify storefront on 2026-10-17 and best-seller ranks collapsed."""
import ssl
from unittest import mock

import build_catalog as bc


def test_bestsellers_use_the_storefront_tls_context():
    seen = {}

    class Page:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self, n): return b'<a href="/products/a-bag">x</a><a href="/products/b-hat">y</a><a href="/products/a-bag">z</a>'

    def fake(req, timeout=None, context=None):
        seen["context"] = context
        seen["url"] = req.full_url
        return Page()

    with mock.patch.object(bc.urllib.request, "urlopen", fake), mock.patch.object(bc, "DELAY", 0):
        assert bc.fetch_bestsellers("shop.example") == ["a-bag", "b-hat"]
    assert seen["context"] is bc.STOREFRONT_TLS
    assert seen["url"] == "https://shop.example/collections/all?sort_by=best-selling"


def test_storefront_tls_still_verifies_certificates():
    ctx = bc.storefront_tls()
    assert ctx.verify_mode == ssl.CERT_REQUIRED and ctx.check_hostname


def test_storefront_tls_without_x25519_keeps_the_default():
    # macOS's /usr/bin/python3 (LibreSSL) can't name the curve; ship.sh runs it.
    with mock.patch.object(ssl.SSLContext, "set_ecdh_curve", side_effect=ssl.SSLError("unknown group")):
        ctx = bc.storefront_tls()
    assert ctx.verify_mode == ssl.CERT_REQUIRED and ctx.check_hostname
