"""A second reading of product pages whose ingredient list the strict reader
(clean_badge.extract_inci) missed.

A 120-page sample of "no published list" pages on 2026-10-09 found a real list
on about 1 in 4: lists a few layout blocks under the "Ingredients" heading,
plain names ("Rose petals, distilled water, aloe vera juice"), "…Avocado Oil
and Fragrance Oil", or a shade label in front ("BROWN'D OUT: DIMETHICONE…").
Loosening the strict reader would also read marketing copy as a list, so this
proposes the comma run right after an "Ingredients" heading and TypeSafe's Jev
confirms it is a full ingredient list (a yes/no; Jev never writes the text —
what is kept is exactly the brand's words). Verdicts are cached by the text
Jev saw in catalog/jev_lists.json, so a page is only asked about once. With no
TYPESAFE_API_KEY nothing is proposed and the strict reader alone decides.
"""
import atexit
import hashlib
import json
import os
import pathlib
import re
import threading

VERDICTS = pathlib.Path(__file__).resolve().parent / "jev_lists.json"
MIN_P = 0.9
_lock = threading.Lock()
_cache = None

HEADING = re.compile(r"\b(?:full |complete )?ingredients?(?: list)?\s*[:\-–]?", re.I)
# Where a list ends: the page's next section.
END = re.compile(r"\b(how to use|directions|to use|usage|uses\s*:|apply|warnings?|caution|cautions|reviews?|share|"
                 r"add to cart|shipping|you may also like|net (?:wt|weight)|size\s*:|scent descriptions?|"
                 r"notes?\s*:|benefits|key benefits|why you|disclaimer|storage|made in|for external use|"
                 r"\*\s*organic|\*\s*certified|recommended use)\b", re.I)
SENTENCE = re.compile(r"\b(our|your|you|we|is|are|this|that|which|will|helps?|while|perfect|designed|made with|"
                      r"crafted|formulated|experience|feel|leaves?)\b", re.I)


def candidate(text):
    """The comma run after an "Ingredients" heading, cleaned, or ""."""
    best = ""
    for m in HEADING.finditer(text):
        chunk = text[m.end():m.end() + 1200]
        chunk = re.sub(r"(\s*\|\s*)+", " | ", chunk).lstrip(" |:")
        stop = END.search(chunk)
        if stop:
            chunk = chunk[:stop.start()]
        # The list is the first segment with commas; a short shade label may lead it.
        segs = [s.strip() for s in chunk.split(" | ") if s.strip()]
        seg = next((s for s in segs if s.count(",") >= 4), "")
        seg = re.sub(r"^[A-Z0-9'’ &\-]{2,30}:\s*", "", seg)       # "BROWN'D OUT: …"
        seg = re.sub(r",?\s+and\s+(?=[^,]+$)", ", ", seg)          # "…Oil and Fragrance Oil"
        seg = seg.strip(" .;")
        toks = [t.strip() for t in seg.split(",") if t.strip()]
        if len(toks) < 5 or max(len(t) for t in toks) > 80:
            continue
        if sum(1 for t in toks if len(t.split()) > 7) > 1 or len(SENTENCE.findall(seg)) > 2:
            continue
        if len(seg) > len(best):
            best = seg
    return best


def _key(seg):
    return hashlib.sha256(seg.encode()).hexdigest()[:16]


def _load():
    global _cache
    if _cache is None:
        _cache = json.loads(VERDICTS.read_text()) if VERDICTS.exists() else {}
    return _cache


def save():
    with _lock:
        if _cache is not None:
            VERDICTS.write_text(json.dumps(_cache, indent=1, ensure_ascii=False, sort_keys=True) + "\n")


def confirmed(seg, title=""):
    """Jev's verdict that `seg` is a full ingredient list (cached)."""
    k = _key(seg)
    with _lock:
        v = _load().get(k)
    if v is None:
        if not os.environ.get("TYPESAFE_API_KEY"):
            return False
        try:
            from typesafe_sdk import Noul, TypeSafeClient
            with TypeSafeClient() as c:
                r = c.system_one(state={"product": title, "text_after_ingredients_heading": seg},
                                 questions={"q": Noul(
                                     instructions="Is this text a list of the product's ingredients, rather "
                                                  "than marketing copy or directions?",
                                     criteria={"true": "Ingredient names separated by commas",
                                               "false": "Sentences describing the product, directions, "
                                                        "shade or vegan notes, or anything that isn't "
                                                        "an ingredient list"})})
            v = round(r.answers["q"].noul, 3)
        except Exception:  # noqa: BLE001 — no verdict means the strict reader stands
            return False
        with _lock:
            _load()[k] = v
    return v >= MIN_P


atexit.register(save)


def retry_misses():
    """MARRACAT_RETRY_MISSES=1 re-reads pages marked "no list" regardless of age."""
    return os.environ.get("MARRACAT_RETRY_MISSES") == "1"


def read(text, title=""):
    """A Jev-confirmed list from the relaxed reading, or ""."""
    seg = candidate(text)
    return seg if seg and confirmed(seg, title) else ""
