"""Release notes become paragraphs with a blank line between them
(scripts/release_notes.py; owner, 2026-10-31)."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_notes import as_paragraphs


def test_bullets_become_paragraphs():
    notes = "• Search finds brands typed without spaces.\n• Every badge has a seal.\n- Sold-out items sit last."
    assert as_paragraphs(notes) == ("Search finds brands typed without spaces.\n\n"
                                    "Every badge has a seal.\n\nSold-out items sit last.")


def test_paragraphs_stay_as_written():
    notes = "A much bigger Marracat.\n\nCheck out from several brands in one go."
    assert as_paragraphs(notes) == notes


def test_hyphenated_words_and_empty_notes_are_left_alone():
    assert as_paragraphs("T-shirts and -50% markdowns.") == "T-shirts and -50% markdowns."
    assert as_paragraphs("") == ""
    assert as_paragraphs(None) is None
