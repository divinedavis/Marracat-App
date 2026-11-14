"""Which hello@marracat.com messages get filed as DMARC reports
(web/mail/dmarc_sort.py; owner, 2026-10-08)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web/mail"))
import dmarc_sort as ds


def test_matches_aggregate_report_subjects():
    assert ds.is_dmarc_report("Report domain: marracat.com Submitter: google.com Report-ID: 7780946360232684271")
    assert ds.is_dmarc_report("Report Domain: marracat.com Submitter: enterprise.protection.outlook.com Report-ID: <x>")
    assert ds.is_dmarc_report("[Preview] Report Domain: marracat.com Submitter: yahoo.com Report-ID: <1>")


def test_leaves_other_mail_alone():
    assert not ds.is_dmarc_report("Re: report domain question from a creator")
    assert not ds.is_dmarc_report("Marracat creator brief")
    assert not ds.is_dmarc_report("")


def test_alias_mail_goes_to_its_folder():
    assert ds.folder_for("<support@marracat.com>", "support@marracat.com") == "Support"
    assert ds.folder_for("<Billing@Marracat.com>", "") == "Billing"
    assert ds.folder_for("", "Shop <orders@marracat.com>") == "Orders", "no envelope header: To decides"
    assert ds.folder_for("<dmarc@marracat.com>", "") == ds.FOLDER


def test_hello_and_creators_stay_in_the_inbox():
    # The creator-reply reader only scans the INBOX.
    assert ds.folder_for("<creators@marracat.com>", "creators@marracat.com") is None
    assert ds.folder_for("<hello@marracat.com>", "hello@marracat.com") is None
    # The envelope says hello@ (e.g. a Bcc'd copy); a To: support@ doesn't overrule it.
    assert ds.folder_for("<hello@marracat.com>", "support@marracat.com") is None
    assert ds.folder_for("", "someone@gmail.com") is None
