"""scripts/sign_catalog.py: signatures the app's CatalogSignature accepts
(audit 2026-10-07, L5). Uses a throwaway key, never the real one.

And the catalog signature's custody: the committed public key is the app's, the signer
on the refresh droplet signs only catalog files, and sign_catalog.py gets a
signature from it over a socket (2026-11-12: the refresh service could read
the key itself until then)."""
import base64
import importlib.machinery
import importlib.util
import io
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import sign_catalog  # noqa: E402

sys.dont_write_bytecode = True   # no __pycache__ beside the signer
_path = str(ROOT / "refresh-server/signer/marracat-sign")
_spec = importlib.util.spec_from_loader("marracat_sign", importlib.machinery.SourceFileLoader("marracat_sign", _path))
signer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(signer)

CATALOG = b'{"generated_at":"2026-11-12T03:55:21Z","products":[' + b'{"id":1},' * 150_000 + b'{"id":2}]}'


def ask(name, body, size=None, sign=lambda data: "SIG"):
    out = io.BytesIO()
    signer.serve(io.BytesIO(f"sign {name} {len(body) if size is None else size}\n".encode() + body), out, sign)
    return out.getvalue().decode().strip()


def test_the_committed_public_key_is_the_one_built_into_the_app():
    swift = (ROOT / "Marracat/Stores/CatalogSignature.swift").read_text()
    built_in = re.search(r'static let publicKey = "([A-Za-z0-9+/=]+)"', swift).group(1)
    assert (ROOT / "scripts/catalog-signing.pub").read_text().strip() == built_in
    assert len(base64.b64decode(built_in)) == 32


def test_the_signer_signs_catalogs_and_deltas_and_nothing_else():
    assert ask("catalog-v3.json", CATALOG) == "ok SIG"
    assert ask("catalog.json", CATALOG) == "ok SIG"
    assert ask("delta-0123456789abcdef.json", b'{"from":"a","ops":[]}') == "ok SIG"
    for name in ["../catalog-v3.json", "catalog-v3.json.sig", "notes.txt", "delta-xyz.json", "catalog-v4.json", "authorized_keys"]:
        assert ask(name, CATALOG).startswith("error"), name
    assert ask("catalog-v3.json", b'{"generated_at":"2026-11-12T03:55:21Z"}') == "error not a catalog", "too small to be one"
    assert ask("catalog-v3.json", b"#!/bin/sh\n" + CATALOG) == "error not a catalog"
    assert ask("catalog-v3.json", CATALOG[:-1]) == "error not a catalog", "cut short"
    assert ask("catalog-v3.json", CATALOG, size=len(CATALOG) + 10) == "error short body"
    assert ask("catalog-v3.json", CATALOG, size=signer.MAX_BYTES + 1) == "error bad size"
    out = io.BytesIO()
    signer.serve(io.BytesIO(b"GET / HTTP/1.1\r\n\r\n"), out)
    assert out.getvalue() == b"error bad request\n"


def test_a_missing_key_is_an_error_not_a_crash_and_names_no_path():
    with mock.patch.object(signer, "KEY", Path("/nonexistent/catalog-signing.key")):
        assert ask("catalog-v3.json", CATALOG, sign=signer.sign) == "error signer failed (FileNotFoundError)"


class SocketSigning(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mcsign"))
        self.private = Ed25519PrivateKey.generate()
        raw = self.private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        (self.tmp / "catalog-signing.pub").write_text(base64.b64encode(raw).decode() + "\n")
        seed = self.private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        (self.tmp / "key").write_text(base64.b64encode(seed).decode())
        self.patches = [mock.patch.object(sign_catalog, "PUBLIC", self.tmp / "catalog-signing.pub"),
                        mock.patch.object(signer, "KEY", self.tmp / "key")]
        for p in self.patches:
            p.start()
        # A short path: a Unix socket's is limited to about 100 bytes.
        self.sock_dir = tempfile.mkdtemp(prefix="mcs", dir="/tmp")
        self.sock_path = os.path.join(self.sock_dir, "s")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.sock_path)
        self.server.listen(2)

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.server.close()
        os.unlink(self.sock_path)
        os.rmdir(self.sock_dir)
        for f in self.tmp.iterdir():
            f.unlink()
        self.tmp.rmdir()

    def answer_with(self, handler):
        def one():
            conn, _ = self.server.accept()
            with conn, conn.makefile("rb") as r, conn.makefile("wb") as w:
                handler(r, w)
        t = threading.Thread(target=one)
        t.start()
        return t

    def test_sign_catalog_asks_the_signer_and_checks_what_comes_back(self):
        f = self.tmp / "catalog-v3.json"
        f.write_bytes(CATALOG)
        t = self.answer_with(signer.serve)
        sign_catalog.sign_by_socket(str(f), self.sock_path, timeout=20)
        t.join(10)
        sign_catalog.verify(sign_catalog.public_key(), str(f))

    def test_a_signature_from_another_key_is_caught_before_a_sig_file_is_written(self):
        other = Ed25519PrivateKey.generate()
        g = self.tmp / "catalog-v2.json"
        g.write_bytes(CATALOG)
        t = self.answer_with(lambda r, w: signer.serve(r, w, lambda d: base64.b64encode(other.sign(d)).decode()))
        with self.assertRaises(Exception):
            sign_catalog.sign_by_socket(str(g), self.sock_path, timeout=20)
        t.join(10)
        self.assertFalse(Path(str(g) + ".sig").exists())

    def test_a_refusal_stops_the_publish(self):
        h = self.tmp / "notes.txt"
        h.write_bytes(CATALOG)
        t = self.answer_with(signer.serve)
        with self.assertRaises(SystemExit):
            sign_catalog.sign_by_socket(str(h), self.sock_path, timeout=20)
        t.join(10)
        self.assertFalse(Path(str(h) + ".sig").exists())


HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "sign_catalog.py"


class SignCatalogTests(unittest.TestCase):
    def run_script(self, env, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True)

    def test_init_sign_verify_and_tamper(self):
        with tempfile.TemporaryDirectory() as d:
            env = {**os.environ, "MARRACAT_CATALOG_KEY": f"{d}/k.key", "MARRACAT_CATALOG_PUB": f"{d}/k.pub"}
            env.pop("MARRACAT_SIGN_SOCKET", None)
            init = self.run_script(env, "--init")
            self.assertEqual(init.returncode, 0, init.stderr)
            self.assertEqual(len(base64.b64decode(init.stdout.strip())), 32)
            self.assertEqual(oct(os.stat(f"{d}/k.key").st_mode & 0o777), "0o600")
            self.assertNotEqual(self.run_script(env, "--init").returncode, 0, "never overwrites a key")
            Path(d, "k.pub").write_text(init.stdout)
            cat = Path(d, "catalog-v3.json")
            cat.write_text('{"generated_at":"2026-10-07T00:00:00Z"}')
            self.assertEqual(self.run_script(env, str(cat)).returncode, 0)
            self.assertEqual(len(base64.b64decode(Path(str(cat) + ".sig").read_text().strip())), 64)
            self.assertEqual(self.run_script(env, "--verify", str(cat)).returncode, 0)
            cat.write_text('{"generated_at":"2026-10-08T00:00:00Z"}')
            self.assertNotEqual(self.run_script(env, "--verify", str(cat)).returncode, 0)

    # 2026-11-12: a signature is checked against the committed public key as
    # it is made, so a key that isn't the app's can't publish.
    def test_signing_with_a_key_that_is_not_the_apps_fails(self):
        with tempfile.TemporaryDirectory() as d:
            env = {**os.environ, "MARRACAT_CATALOG_KEY": f"{d}/k.key"}
            env.pop("MARRACAT_SIGN_SOCKET", None)
            env.pop("MARRACAT_CATALOG_PUB", None)
            self.assertEqual(self.run_script(env, "--init").returncode, 0)
            cat = Path(d, "catalog-v3.json")
            cat.write_text('{"generated_at":"2026-10-07T00:00:00Z"}')
            self.assertNotEqual(self.run_script(env, str(cat)).returncode, 0)

    def test_app_embeds_the_real_public_key(self):
        swift = (HERE.parent / "Marracat/Stores/CatalogSignature.swift").read_text()
        key = re.search(r'publicKey = "([A-Za-z0-9+/=]+)"', swift).group(1)
        self.assertEqual(len(base64.b64decode(key)), 32)
        real = Path.home() / ".config/marracat/catalog-signing.key"
        if real.exists():
            env = {k: v for k, v in os.environ.items() if k not in ("MARRACAT_CATALOG_KEY", "MARRACAT_SIGN_SOCKET")}
            out = subprocess.run([sys.executable, str(SCRIPT), "--public"], capture_output=True, text=True, env=env).stdout.strip()
            self.assertEqual(out, key, "the app's key must match the publishing key")


if __name__ == "__main__":
    unittest.main()
