"""clear_rejections takes out only this job's own items (events, holiday
art), never the app version a person submitted (it pulled Marracat 1.14 out
of its submission on 2026-11-18)."""
import json, pathlib, sys, tempfile, unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "asc_growth"))
# mc_growth needs the ASC key helper that lives outside the repo; the test
# replaces every call it makes anyway.
import types
sys.modules.setdefault("mc_growth", types.SimpleNamespace(APP="0", call=None, library=None, upload=None))
import mc_holidays_auto as job


class ClearRejections(unittest.TestCase):
    def test_takes_out_a_rejected_event_but_never_the_app_version(self):
        items = {"data": [
            {"id": "EVT", "attributes": {"state": "REJECTED"},
             "relationships": {"appEvent": {"data": {"type": "appEvents", "id": "6831955420"}}}},
            {"id": "VER", "attributes": {"state": "REJECTED"},
             "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": "v1"}}}},
            {"id": "OK", "attributes": {"state": "APPROVED"},
             "relationships": {"appEvent": {"data": {"type": "appEvents", "id": "2"}}}},
        ], "included": [
            {"type": "appEvents", "id": "6831955420", "attributes": {"referenceName": "Standing spotlight 2026-12"}},
            {"type": "appEvents", "id": "2", "attributes": {"referenceName": "Other"}},
        ]}
        patched = []
        def call(method, path, body=None):
            if method == "GET":
                return items
            patched.append(path)
            return {}
        with tempfile.TemporaryDirectory() as d:
            held = pathlib.Path(d) / "rejected.json"
            with mock.patch.object(job, "call", call), mock.patch.object(job, "HELD", held), \
                 mock.patch.object(job, "open_submission", lambda: ("sub", "UNRESOLVED_ISSUES")), \
                 mock.patch.object(job, "log", lambda *a: None):
                job.clear_rejections(apply=True)
            self.assertEqual(patched, ["/v1/reviewSubmissionItems/EVT"])
            self.assertEqual(json.loads(held.read_text()), ["Standing spotlight 2026-12"])


class Planned(unittest.TestCase):
    def test_no_brand_spotlight_event_after_app_review_said_no(self):
        from datetime import date
        refs = [x["ref"] for x in job.planned(date(2026, 12, 20))]
        self.assertFalse([r for r in refs if "spotlight" in r], "2.3.13: events can't promote physical goods")


if __name__ == "__main__":
    unittest.main()
