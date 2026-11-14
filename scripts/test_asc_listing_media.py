"""scripts/asc_listing_media.py against a fake App Store Connect: it picks
the version being prepared, refuses when there is none, and a dry run
writes nothing."""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import asc_listing_media as m  # noqa: E402


class FakeASC:
    def __init__(self, versions, shots=None):
        self.versions, self.writes = versions, []
        self.shots = shots if shots is not None else [{"id": "old1", "attributes": {"fileName": "a.png"}}]

    def __call__(self, token, method, path, params=None, body=None, ok_statuses=()):
        if method != "GET":
            self.writes.append((method, path))
            return 200, {"data": {"id": "new", "attributes": {"uploadOperations": []}}}
        if path.endswith("/appStoreVersions"):
            return 200, {"data": [{"id": vid, "attributes": {"versionString": vs, "appStoreState": st}}
                                  for vid, vs, st in self.versions]}
        if path.endswith("/appStoreVersionLocalizations"):
            return 200, {"data": [{"id": "loc-en", "attributes": {"locale": "en-US"}},
                                  {"id": "loc-mx", "attributes": {"locale": "es-MX"}}]}
        if path.endswith("/appScreenshotSets"):
            return 200, {"data": [{"id": "set67", "attributes": {"screenshotDisplayType": "APP_IPHONE_67"}}]}
        if path.endswith("/appScreenshots"):
            return 200, {"data": self.shots}
        if "/appScreenshots/" in path:
            return 200, {"data": {"attributes": {"assetDeliveryState": {"state": "COMPLETE"}}}}
        if path.endswith("/appPreviewSets"):
            return 200, {"data": [{"id": "pv67", "attributes": {"previewType": "IPHONE_67"}}]}
        raise AssertionError(path)


class ListingMediaTests(unittest.TestCase):
    def test_picks_the_version_being_prepared(self):
        m.api = FakeASC([("v19", "1.9", "READY_FOR_SALE"), ("v110", "1.10", "PREPARE_FOR_SUBMISSION")])
        self.assertEqual(m.localization("t", "app", "en-US"), ("1.10", "loc-en"))

    def test_refuses_when_only_the_live_version_exists(self):
        m.api = FakeASC([("v19", "1.9", "READY_FOR_SALE")])
        with self.assertRaises(SystemExit) as e:
            m.localization("t", "app", "en-US")
        self.assertIn("create_version.py", str(e.exception))

    def test_a_dry_run_writes_nothing(self):
        fake = m.api = FakeASC([("v110", "1.10", "PREPARE_FOR_SUBMISSION")])
        with tempfile.TemporaryDirectory() as d:
            png = pathlib.Path(d) / "01.png"
            png.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 10)
            mp4 = pathlib.Path(d) / "p.mp4"
            mp4.write_bytes(b"0" * 10)
            m.replace_screens("t", "loc-en", "APP_IPHONE_67", [png], dry=True)
            m.replace_preview("t", "loc-en", "APP_IPHONE_67", mp4, "00:00:05:00", dry=True)
        self.assertEqual(fake.writes, [])

    def test_refuses_a_screenshot_that_is_not_a_png(self):
        m.api = FakeASC([("v110", "1.10", "PREPARE_FOR_SUBMISSION")])
        with tempfile.TemporaryDirectory() as d:
            jpg = pathlib.Path(d) / "01.jpg"
            jpg.write_bytes(b"\xff\xd8\xff")
            with self.assertRaises(SystemExit):
                m.replace_screens("t", "loc-en", "APP_IPHONE_67", [jpg], dry=True)

    def test_a_rerun_keeps_what_already_uploaded_and_deletes_the_rest(self):
        import hashlib
        with tempfile.TemporaryDirectory() as d:
            one, two = pathlib.Path(d) / "01.png", pathlib.Path(d) / "02.png"
            one.write_bytes(b"\x89PNG\r\n\x1a\n" + b"1")
            two.write_bytes(b"\x89PNG\r\n\x1a\n" + b"2")
            sent = {"fileName": "01.png", "sourceFileChecksum": hashlib.md5(one.read_bytes()).hexdigest(),
                    "assetDeliveryState": {"state": "UPLOAD_COMPLETE"}}
            old = {"fileName": "old.png", "sourceFileChecksum": "x", "assetDeliveryState": {"state": "COMPLETE"}}
            fake = m.api = FakeASC([("v110", "1.10", "PREPARE_FOR_SUBMISSION")],
                                   shots=[{"id": "s1", "attributes": sent}, {"id": "s0", "attributes": old}])
            m.replace_screens("t", "loc-en", "APP_IPHONE_67", [one, two], dry=True)
            self.assertEqual(fake.writes, [], "a dry run still writes nothing")
            m.replace_screens("t", "loc-en", "APP_IPHONE_67", [one, two], dry=False)
        self.assertIn(("DELETE", "/appScreenshots/s0"), fake.writes, "the old file goes")
        self.assertNotIn(("DELETE", "/appScreenshots/s1"), fake.writes, "the one already sent stays")
        self.assertEqual(fake.writes.count(("POST", "/appScreenshots")), 1, "only 02 uploads")
        self.assertEqual(fake.writes[-1], ("PATCH", "/appScreenshotSets/set67/relationships/appScreenshots"),
                         "the set is put in the files' order last")


    def test_a_preview_goes_to_the_slot_named_without_app(self):
        fake = m.api = FakeASC([("v110", "1.10", "PREPARE_FOR_SUBMISSION")])
        with tempfile.TemporaryDirectory() as d:
            mp4 = pathlib.Path(d) / "p.mp4"
            mp4.write_bytes(b"0" * 10)
            m.wait_done = lambda *a, **k: None
            m.replace_preview("t", "loc-en", "APP_IPHONE_67", mp4, None, dry=False)
        self.assertIn(("DELETE", "/appPreviewSets/pv67"), fake.writes, "the IPHONE_67 preview set is replaced")


if __name__ == "__main__":
    unittest.main()
