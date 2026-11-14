"""Marracat Clean for candles.

Candles aren't cosmetics, so the cosmetics ban lists in clean_badge.py don't
govern them, and almost nothing in a candle is banned anywhere. The badge keeps
its meaning by applying the same three ideas to what a candle is made of:

1. Materials are published. The listing names its wax and its wick, the
   candle's equivalent of an ingredient list. No materials, no badge.
2. Nothing banned anywhere. Lead-core wicks are banned in the US (CPSC, 2003)
   and Australia (2002), and zinc or other metal cores are how lead used to be
   hidden, so any metal-core wick fails.
3. Fragrance is disclosed. A candle sold in the EU must name its fragrance
   allergens on the label (CLP, EUH208), but online listings almost never do.
   The nearest thing a listing can show is where the scent comes from: essential
   oils, a fragrance stated phthalate-free, or none at all. "Fragrance oil" alone
   fails, as "fragrance" alone does on a lotion.

Paraffin is allowed and noted, the way petrolatum is for hair: it isn't banned
anywhere, and the standard doesn't pretend otherwise.

Read from the listing's own description, tags and title. Stdlib only.
"""
import re

# A candle, not something that goes with one.
CANDLE = re.compile(r"\bcandles?\b", re.I)
NOT_A_CANDLE = re.compile(
    r"\b(holders?|trimmers?|snuffers?|warmers?|lids?|dish|tray|mats?|matches|lighters?|toppers?|"
    r"empty|stand|sconce|lantern|making kit|diy kit|wick(s)? only|refill|gift card|class|workshop|"
    r"sticker|label|shirt|hoodie|tee|print|poster|"
    # Sets hold several candles one listing can't vouch for, as with cosmetics.
    r"sets?|trio|duo|bundle|collection|sampler|gift box|\d[- ]?pack)\b", re.I)

WAX = re.compile(r"\b(soy|coconut|beeswax|bees wax|rapeseed|canola|apricot|palm|paraffin|vegetable|plant[- ]based|"
                 r"coco[- ]?(?:soy|apricot)|natural) ?(?:and [a-z]+ )?(?:wax|blend)|\bbeeswax\b|\bsoy\b(?=[^.]{0,30}\bwax)", re.I)
WICK = re.compile(r"\b(cotton|wood(?:en)?|hemp|paper|crackling|lead[- ]free|zinc[- ]free|natural)[^.]{0,20}\bwicks?\b|\bwicks?\b[^.]{0,25}\b(cotton|wood|hemp)", re.I)
METAL_WICK = re.compile(r"\b(lead|zinc|metal)[- ]?(core|cored|wick)", re.I)
METAL_FREE = re.compile(r"\b(lead|zinc|metal)[- ]?free\b|\bno (lead|zinc|metal)\b|\bwithout (lead|zinc)\b", re.I)
ESSENTIAL_OILS = re.compile(r"\bessential oils?\b", re.I)
PHTHALATE_FREE = re.compile(r"phthalate[s]?[- ]free|free (?:of|from) phthalates|no phthalates|without phthalates", re.I)
UNSCENTED = re.compile(r"\bunscented\b|\bfragrance[- ]free\b|\bscent[- ]free\b|\bno (added )?(fragrance|scent)\b", re.I)
FRAGRANCE_OIL = re.compile(r"\b(fragrance|perfume|scent)(?:ed)? oils?\b|\bfragrance\b(?! free)|\bparfum\b", re.I)
PARAFFIN = re.compile(r"\bparaffin\b(?![- ]free)", re.I)
NO_PARAFFIN = re.compile(r"\b(no|without|zero|non)[- ]paraffin\b|\bparaffin[- ]free\b|\bfree (?:of|from) paraffin", re.I)


def is_candle(product):
    text = f"{product.get('title', '')} {product.get('product_type') or ''}"
    return bool(CANDLE.search(text)) and not NOT_A_CANDLE.search(text)


def text_of(product):
    return " ".join([product.get("title") or "", product.get("description") or "", " ".join(product.get("tags") or [])])


def evaluate_candle(product):
    """-> (passes, failures, notes)"""
    t = text_of(product)
    failures, notes = [], []
    if not WAX.search(t) or not WICK.search(t):
        failures.append("materials not published: the listing doesn't name its wax and wick")
    if METAL_WICK.search(t) and not METAL_FREE.search(t):
        failures.append("metal-core wick: lead-core wicks are banned in the US and Australia")
    scented = not UNSCENTED.search(t)
    if scented and not (ESSENTIAL_OILS.search(t) or PHTHALATE_FREE.search(t)):
        failures.append("undisclosed fragrance: name essential oils or state the fragrance is phthalate-free")
    if scented and FRAGRANCE_OIL.search(t) and ESSENTIAL_OILS.search(t) and not PHTHALATE_FREE.search(t):
        # "Essential and fragrance oils": the fragrance oil part is still undisclosed.
        if re.search(r"\b(fragrance|perfume) oils?\b", t, re.I):
            failures.append("undisclosed fragrance: essential oils blended with a fragrance oil not stated phthalate-free")
    if PARAFFIN.search(t) and not NO_PARAFFIN.search(t):
        notes.append("paraffin wax")
    return not failures, failures, notes
