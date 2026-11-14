"""The refresh droplet's pieces (refresh-server/, 2026-10-12): the publish
receiver's forced command only does what it lists, generated state survives a
code update, and alert emails are rate-limited."""
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
RS = ROOT / "refresh-server"


def load(name):
    spec = importlib.util.spec_from_file_location(name, RS / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


merge_state = load("merge_state")
notify = load("notify")


class MergeState(unittest.TestCase):
    def test_droplet_cache_kept_when_upstream_did_not_touch_it(self):
        self.assertEqual(merge_state.merge('{"a":1,"b":2}', '{"a":0}', False), '{"a":1,"b":2}')

    def test_both_sides_entries_kept_droplet_wins_a_clash(self):
        out = json.loads(merge_state.merge('{"a":1,"c":3}', '{"a":0,"b":2}', True))
        self.assertEqual(out, {"a": 1, "b": 2, "c": 3})

    def test_sorted_upstream_stays_sorted_and_keeps_its_layout(self):
        out = merge_state.merge('{"z":1}', '{\n"a":1,\n"b":2\n}\n', True)
        self.assertEqual(list(json.loads(out)), ["a", "b", "z"])
        self.assertTrue(out.endswith("\n"))
        self.assertIn("\n", out.strip())

    def test_reports_follow_upstream_only_when_it_changed_them(self):
        self.assertEqual(merge_state.merge("droplet report", "hand edit", True), "hand edit")
        self.assertEqual(merge_state.merge("droplet report", "old", False), "droplet report")


class Alerts(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.old = notify.STATE
        notify.STATE = self.dir
        self.addCleanup(setattr, notify, "STATE", self.old)

    def test_same_subject_at_most_once_an_hour(self):
        self.assertFalse(notify.recently_sent("x", now=1_000_000))
        self.assertTrue(notify.recently_sent("x", now=1_000_000 + 60))
        self.assertFalse(notify.recently_sent("y", now=1_000_000 + 60))
        self.assertFalse(notify.recently_sent("x", now=1_000_000 + 3700))

    def test_message_goes_to_the_owner_from_the_mailbox(self):
        m = notify.build("s", "b", {"user": "hello@example.com"})
        self.assertIn("hello@example.com", m["From"])
        self.assertEqual(m["To"], notify.TO)


class Receiver(unittest.TestCase):
    """refresh-server/receiver/marracat-pub-ssh, with sudo replaced by echo."""

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)

    def run_cmd(self, cmd, stdin=b""):
        env = {**os.environ, "SSH_ORIGINAL_COMMAND": cmd, "MARRACAT_PUB_INCOMING": str(self.dir),
               "MARRACAT_PUB_SUDO": "echo SUDO"}
        return subprocess.run(["bash", str(RS / "receiver" / "marracat-pub-ssh")], input=stdin,
                              capture_output=True, env=env)

    def test_put_of_a_listed_file_lands_and_reports_its_md5(self):
        r = self.run_cmd("put catalog-v3.json.gz", b"hello")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.decode().strip(), hashlib.md5(b"hello").hexdigest())
        self.assertEqual((self.dir / "catalog-v3.json.gz").read_bytes(), b"hello")
        self.assertEqual([p.name for p in self.dir.iterdir()], ["catalog-v3.json.gz"])

    def test_anything_else_is_refused(self):
        for cmd in ["put ../catalog.json", "put /etc/passwd", "put catalog.json extra", "put index.html",
                    "put catalog.json;id", "put $(id)", "rm -rf /", "bash", "", "catalog-swap now",
                    "web-data-release 2026-10-12T00:00:00Z", "web-data-release x y",
                    "web-rollback ../../x", "web-rollback 20261012T000000Z extra", "scp -t /tmp"]:
            r = self.run_cmd(cmd, b"x")
            self.assertEqual(r.returncode, 2, cmd)
            self.assertNotIn(b"SUDO", r.stdout, cmd)
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_the_root_steps_are_reached_only_through_sudo_with_checked_arguments(self):
        r = self.run_cmd("catalog-swap")
        self.assertEqual(r.stdout.decode().strip(), "SUDO /usr/local/sbin/marracat-catalog-swap")
        r = self.run_cmd("web-data-release 2026-10-12T17:00:01.123Z p-123_abc")
        self.assertEqual(r.stdout.decode().strip(),
                         "SUDO /usr/local/sbin/marracat-web-data-release release 2026-10-12T17:00:01.123Z p-123_abc")
        r = self.run_cmd("web-rollback 20261012T170001Z")
        self.assertEqual(r.stdout.decode().strip(),
                         "SUDO /usr/local/sbin/marracat-web-data-release rollback 20261012T170001Z")


class SignatureCheck(unittest.TestCase):
    """receiver/marracat-verify-sig and the delta step that calls it
    (2026-11-12: an upload's .sig only had to be under 100 bytes)."""

    def setUp(self):
        import base64
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.key, self.other = Ed25519PrivateKey.generate(), Ed25519PrivateKey.generate()
        raw = self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        (self.dir / "pub").write_text(base64.b64encode(raw).decode() + "\n")
        self.b64 = lambda key, data: base64.b64encode(key.sign(data)).decode() + "\n"
        self.env = {**os.environ, "MARRACAT_CATALOG_PUB": str(self.dir / "pub")}

    def verify(self, path):
        return subprocess.run([os.sys.executable, str(RS / "receiver" / "marracat-verify-sig"), str(path)], capture_output=True, env=self.env)

    def test_only_the_catalog_keys_signature_passes(self):
        f = self.dir / "catalog-v3.json"
        f.write_bytes(b'{"products":[]}')
        (self.dir / "catalog-v3.json.sig").write_text(self.b64(self.key, f.read_bytes()))
        self.assertEqual(self.verify(f).returncode, 0)
        f.write_bytes(b'{"products":[1]}')
        self.assertNotEqual(self.verify(f).returncode, 0, "the file changed after signing")
        (self.dir / "catalog-v3.json.sig").write_text(self.b64(self.other, f.read_bytes()))
        self.assertNotEqual(self.verify(f).returncode, 0, "another key's signature")
        for junk in ["", "not base64!!\n", "QUJD\n", "A" * 500]:
            (self.dir / "catalog-v3.json.sig").write_text(junk)
            self.assertNotEqual(self.verify(f).returncode, 0, junk[:12])
        (self.dir / "catalog-v3.json.sig").unlink()
        self.assertNotEqual(self.verify(f).returncode, 0, "no signature at all")

    # The delta step is the droplet's (GNU stat and md5sum): this runs there,
    # in the tests before every publish, and is skipped on the Mac.
    @unittest.skipUnless(os.sys.platform == "linux", "marracat-catalog-deltas needs GNU stat and md5sum")
    def test_a_delta_goes_live_only_with_the_catalog_keys_signature(self):
        import gzip
        src, live = self.dir / "src", self.dir / "live"
        src.mkdir()
        good, forged = "delta-" + "a" * 16 + ".json", "delta-" + "b" * 16 + ".json"
        for name, key in [(good, self.key), (forged, self.other)]:
            body = b'{"from":"x","ops":[]}'
            (src / name).write_bytes(body)
            (src / (name + ".gz")).write_bytes(gzip.compress(body))
            (src / (name + ".sig")).write_text(self.b64(key, body))
        (src / ("manifest-" + "c" * 16 + ".json.gz")).write_bytes(gzip.compress(b"{}"))
        verifier = self.dir / "verify"
        verifier.write_text(f"#!/bin/sh\nexec {os.sys.executable} {RS / 'receiver' / 'marracat-verify-sig'} \"$@\"\n")
        verifier.chmod(0o755)
        r = subprocess.run(["bash", str(RS / "receiver" / "marracat-catalog-deltas"), str(src)], capture_output=True,
                           env={**self.env, "MARRACAT_DELTA_DIR": str(live), "MARRACAT_VERIFY_SIG": str(verifier)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((live / good).exists())
        self.assertFalse((live / forged).exists(), "a delta signed by another key stays out")
        self.assertIn(b"not signed by the catalog key", r.stderr)

    def test_the_swap_checks_each_catalog_before_anything_goes_live(self):
        swap = (RS / "receiver" / "marracat-catalog-swap").read_text()
        check = swap.index('/usr/local/sbin/marracat-verify-sig "$IN/$name"')
        self.assertLess(check, swap.index('install -m 644 -o root -g root "$IN/$f" "$DOCROOT/$f.tmp"'))


if __name__ == "__main__":
    unittest.main()
