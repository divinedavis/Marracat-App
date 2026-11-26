"""Second pass over the keyword categoriser's department: the merchant's own
product type, and gift sets that should sit with what's inside them.

categorize() (build_catalog.py) scores keywords. Two of its blind spots showed
on 2026-10-10 when Lillie Mae (handmade bath and body) was added: 11 of its
111 products landed outside skincare —

  - "Body, Gift Set" and "(Full Log) Rosehip and Cranberry" went to Party,
    because "gift set" is a party keyword and nothing else in them scored;
  - "Oud Elemi and Beet Root Powder Soap" went to Makeup on "powder", and
    "Belizean Coffee Soap Bar" to Grocery on "coffee", though the merchant's
    product type said "Soap".

So:
  1. A product type that plainly names a department ("Soap", "Skin",
     "Candles", "Hoodies") is the merchant filing the product itself, and wins.
  2. A gift set, bundle, kit, sampler or soap "full log" is judged without
     those words; when nothing else in it names a department, it goes where
     the brand's own other products go.

Neither touches a product placed on purpose: a brands.json pin that differs
from the keyword guess (hand review), or a confident Jev verdict
(jev_categories.json) for the product as it reads now.
"""
import collections
import hashlib
import re

from taxonomy import subcategories_of, with_added_aisles

# Product-type words that name one department. Matched against each part of
# the type ("Body, Gift Set" -> "body", "gift set"), whole part only, so a
# type like "Hair Accessories" is not "hair".
TYPE_DEPARTMENTS = {
    "skincare": ["skin", "skincare", "skin care", "body care", "soap", "soaps",
                 "bar soap", "bar soaps", "body wash", "body butter", "body butters", "face", "facial",
                 "face care", "lotion", "lotions", "moisturizer", "cleanser", "serum", "serums",
                 "sunscreen", "body oil", "body oils", "body scrub", "scrubs", "creams"],
    "hair": ["hair", "hair care", "haircare", "shampoo", "conditioner", "wig", "wigs",
             "hair extensions", "hair oil"],
    "makeup": ["makeup", "make up", "cosmetics", "lips", "lipstick", "lip gloss", "eyes",
               "foundation", "nail polish"],
    "fragrance": ["fragrance", "fragrances", "perfume", "perfumes", "cologne", "eau de parfum",
                  "body mist", "perfume oil"],
    "home": ["candle", "candles", "home", "home decor", "home fragrance", "decor", "kitchen",
             "bedding", "wax melt", "wax melts", "drinkware"],
    "household": ["laundry", "cleaning", "cleaning supplies", "detergent", "household"],
    "clothing": ["apparel", "clothing", "tops", "t-shirt", "t-shirts", "tee", "tees", "hoodie",
                 "hoodies", "dress", "dresses", "pants", "shorts", "outerwear", "jackets",
                 "sweatshirt", "sweatshirts", "bottoms", "swimwear", "activewear", "lingerie",
                 "loungewear", "ready to wear"],
    "shoes": ["shoes", "footwear", "sneakers", "boots", "sandals"],
    "bags": ["bags", "handbags", "handbag", "totes", "tote bags", "backpacks", "bags and packs"],
    "jewelry": ["jewelry", "jewellery", "necklace", "necklaces", "earrings", "rings", "bracelets"],
    # Not "accessories": stores file hair cuffs, candle wick dippers and
    # headphone cushions under it, so it names no department of ours.
    "accessories": ["hats", "caps", "scarves", "sunglasses", "socks", "headwear"],
    "grocery": ["food", "snacks", "snack", "beverage", "beverages", "sauce", "sauces", "spices",
                "seasoning", "seasonings", "candy", "chocolate", "herbs"],
    "wellness": ["supplement", "supplements", "vitamins", "wellness"],
    "books": ["book", "books", "paperback", "hardcover"],
    "pets": ["pet", "pets", "pet supplies"],
    "toys": ["toys", "toy", "games", "puzzle", "puzzles"],
    "party": ["greeting card", "greeting cards", "gift wrap", "party supplies", "balloons"],
}
_TYPE_INDEX = {w: dept for dept, words in TYPE_DEPARTMENTS.items() for w in words}
# Whole types that would split into vaguer parts ("Bath & Beauty" is lashes
# as often as soap, so plain "bath" is not on the list).
WHOLE_TYPES = {"bath & body": "skincare", "bath and body": "skincare", "bath & body works": "skincare",
               "bags & packs": "bags", "bags and packs": "bags", "jackets and otw": "clothing"}
# "Body" names skin care at a bath-and-body brand and a bodysuit at a
# clothing label, so it only counts where the brand already lives there.
_BODY_BRANDS = {"skincare"}

# A gift set is a container; the department is what's in it.
# ("Set of 6 Cards", "Puff Duo" and "Trio" name a quantity, not a gift.)
GIFTISH = re.compile(r"\bgift[\s\-]?sets?\b|\bgift[\s\-]?box(?:es)?\b|\bgift basket\b|\bbundles?\b|"
                     r"\bfull[\s\-]?logs?\b|\bsamplers?\b|\bkits?\b|\bbox set\b", re.I)

# Product nouns the keyword table doesn't carry but that clearly name a
# department, used only to weigh the evidence below (adding "soap" to the
# keyword table itself would re-file thousands of frozen placements).
EXTRA_EVIDENCE = {
    "skincare": ["soap", "bar soap", "soap bar", "body butter", "shea butter", "bath salt", "bath bomb",
                 "body polish", "sugar scrub", "shower steamer", "shower steamers"],
    "makeup": ["eye pencil", "lip pencil", "eye liner"],
    "clothing": ["tshirt"],
    # Owner review 2026-10-11: a watch gift set went to Home and a shower
    # steamer to Garden for want of these.
    "accessories": ["timepiece", "wristwatch"],
    "hair": ["scalp", "scalp exfoliant", "scalp scrub"],
}


def type_parts(product_type):
    parts = re.split(r"\s*(?:,|/|&|\||;|>|\band\b)\s*", (product_type or "").lower())
    return [re.sub(r"\s+", " ", p).strip(" .-") for p in parts if p.strip(" .-")]


def type_vote(product_type, brand_category):
    """The one department the merchant's product type names, or None."""
    whole = re.sub(r"\s+", " ", (product_type or "").lower()).strip()
    if whole in WHOLE_TYPES:
        return WHOLE_TYPES[whole]
    depts = set()
    for part in type_parts(product_type):
        if GIFTISH.search(part):
            continue
        if part == "body":
            if brand_category in _BODY_BRANDS:
                depts.add(brand_category)
            continue
        if part not in _TYPE_INDEX:
            # A part we can't place may be the real product noun
            # ("Flashcards / Decor" is classroom cards, not home decor), so the
            # type doesn't plainly name one department.
            return None
        depts.add(_TYPE_INDEX[part])
    return depts.pop() if len(depts) == 1 else None


def is_giftish(row):
    return bool(GIFTISH.search(row.get("title") or "") or GIFTISH.search(row.get("product_type") or ""))


def _strip_gift(text):
    return re.sub(r"\s+", " ", GIFTISH.sub(" ", text or "")).strip()


def _without_gift_words(row):
    return {**row, "title": _strip_gift(row.get("title")), "product_type": _strip_gift(row.get("product_type")),
            "tags": [t for t in (row.get("tags") or []) if not GIFTISH.search(t)]}


class Evidence:
    """Which departments a text names, by the build's keyword table plus
    EXTRA_EVIDENCE, honouring its DISQUALIFY list. Gift words are stripped
    first: "Gift Set" is packaging, not a reason to sit in Party."""

    def __init__(self, bc):
        self.patterns = {cat: [p for _k, p in pats] for cat, pats in bc._patterns.items()}
        for cat, words in EXTRA_EVIDENCE.items():
            self.patterns.setdefault(cat, []).extend(bc._pattern(w) for w in words)
        self.disqualify = bc.DISQUALIFY

    def __call__(self, text):
        return set(self.where(text))

    def where(self, text):
        """{department: where its last keyword ends}. English puts the product
        noun last ("Beet Root Powder Soap", "Coffee Soap Bar"), so when two
        departments are named, the later one is what the thing is."""
        text = _strip_gift(text)
        out = {}
        if not text:
            return out
        for cat, pats in self.patterns.items():
            if cat == "alcohol" or any(p.search(text) for p in self.disqualify.get(cat, [])):
                continue
            ends = [m.end() for p in pats for m in p.finditer(text)]
            if ends:
                out[cat] = max(ends)
        return out


def photo_key(row):
    """Same key as photo_categories.vkey: product id + first photo URL."""
    return hashlib.sha1(f"{row['id']}|{(row.get('images') or [''])[0]}".encode()).hexdigest()[:20]


def handle(row):
    return (row.get("url") or "").rsplit("/products/", 1)[-1].rsplit("/product/", 1)[-1].split("?")[0]


def hand_pinned(row, brand, bc):
    """A department set by hand: a brands.json product_categories entry that
    differs from the keyword guess, or any entry whose handle is listed in the
    brand's pinned_handles (a review that confirmed the keyword guess, e.g. a
    photo-check false positive, 2026-10-12; without the list it would look
    like an import freezing the guess and could be moved again)."""
    h = handle(row)
    pinned = (brand.get("product_categories") or {}).get(h)
    if not pinned:
        return False
    if h in (brand.get("pinned_handles") or ()):
        return True
    # Not a pin that only froze the old bare-word guess for Pet Supplies.
    return pinned != bc.categorize(row, brand) and not bc.frozen_pet_guess(pinned, row, brand, h)


def placed_on_purpose(row, brand, bc):
    """A hand pin, a confident Jev verdict for the product as it reads now, or
    a photo-check move (photo_categories.py) for its current photo."""
    if hand_pinned(row, brand, bc):
        return True
    m = (getattr(bc, "PHOTO_MOVES", None) or {}).get(row.get("id"))
    if m and m["to"] == row.get("category") and m["photo"] == photo_key(row):
        return True
    v = bc.JEV.get(row["id"])
    return bool(bc.jev_confident(v) and v["choice"] == row["category"]
                and v["seen"] == bc.jev_key(row))


# A gift set that names nothing follows the brand only where the brand clearly
# lives in one department; at a mixed brand (a watch set at a label that is
# 34% home, 21% clothing, 20% party) the guess is no better than Party.
MODE_SHARE = 0.5


def brand_mode(rows, brand):
    """Where this brand's own (non-gift) products mostly sit, or None when no
    department holds at least MODE_SHARE of them."""
    counts = collections.Counter(r["category"] for r in rows if not is_giftish(r))
    total = sum(counts.values())
    if total < 3:
        return brand.get("category")
    mode, n = counts.most_common(1)[0]
    return mode if n / total >= MODE_SHARE else None


def proposed(row, brand, mode, evidence):
    """The department these rules give, or None to leave it where it is."""
    current = row["category"]
    at = evidence.where(row.get("title"))
    title_ev = set(at)
    vote = type_vote(row.get("product_type"), brand.get("category"))
    if vote:
        # The merchant's type wins when the title says nothing for where the
        # product sits now, or when the title names both and the type's
        # department comes last. A "Decor" book whose title ends in "Book"
        # stays in Books; "Beet Root Powder Soap" filed as Soap leaves Makeup.
        if current not in title_ev or (vote in title_ev and at[vote] > at[current]):
            return vote
        return None
    if is_giftish(row):
        # Gift words are already out of the evidence, so "Greeting Card
        # Bundle" still names Party and stays there.
        ev = title_ev | evidence(row.get("product_type"))
        if current in ev:
            return None              # something real in it names where it is
        if len(ev) == 1:
            return ev.pop()          # ...or names one other department
        if not ev and current == "party" and mode:
            return mode              # only "gift" put it in Party: the brand's mix decides
    return None


def refine(rows, brand, bc, evidence=None):
    """Re-file one brand's rows in place; returns [(row, old, new)]."""
    evidence = evidence or Evidence(bc)
    mode = brand_mode(rows, brand)
    moved = []
    for r in rows:
        if placed_on_purpose(r, brand, bc):
            continue
        new = proposed(r, brand, mode, evidence)
        if new and new != r["category"]:
            moved.append((r, r["category"], new))
            r["category"] = new
            r["subs"] = with_added_aisles(r, new, subcategories_of(r, new))
    return moved


# Sex toys and their gear go to Wellness > Sexual Wellness, whatever the
# keywords, a pin, Jev or a photo check said (owner, 2026-11-16, on the age
# rating: two New York Toy Collective strap-on and packer kits had landed in
# Bags and Accessories, where a shopper browsing for a tote would meet them).
# Home keeps that aisle off its shared rows (Product.keptOffHome).
ADULT_AISLE = "sexual-wellness"
# Whole product-type parts a store only uses for these.
ADULT_TYPES = {"dildo", "dildos", "vibe", "vibes", "vibrator", "vibrators", "sex toy", "sex toys",
               "adult toy", "adult toys", "strap-on", "strap-ons", "strap-on kit", "strap-on kits",
               "strap-on harness", "strap-on harnesses", "butt plug", "butt plugs", "anal toys",
               "masturbator", "masturbators", "stroker", "strokers", "cock ring", "cock rings"}
# Title words that can't mean anything else. Not "vibrator": The Vibrators
# are a punk band with CDs in the catalog.
ADULT_TITLE = re.compile(r"\b(?:dildos?|strap[\s\-]?ons?|butt[\s\-]plugs?|cock[\s\-]rings?|"
                         r"sex[\s\-]toys?|masturbators?)\b", re.I)
# Departments whose titles only talk about these (a book, a record).
_ADULT_TITLE_EXEMPT = {"books", "music", "art"}


def adult_brand(brand):
    """A brand whose hand-checked products are all Sexual Wellness: every
    product it lists is, including the bundles the pins never saw."""
    subs = list((brand.get("product_subcategories") or {}).values())
    return len(subs) >= 3 and all(s and s[0] == ADULT_AISLE for s in subs)


def is_adult(row, brand):
    if adult_brand(brand):
        return True
    if any(p in ADULT_TYPES for p in type_parts(row.get("product_type"))):
        return True
    return row.get("category") not in _ADULT_TITLE_EXEMPT and bool(ADULT_TITLE.search(row.get("title") or ""))


def file_adult(rows, brand):
    """Runs last, after every other move. Returns the rows it changed."""
    moved = []
    for r in rows:
        if not is_adult(r, brand):
            continue
        subs = [ADULT_AISLE] + [s for s in (r.get("subs") or []) if s != ADULT_AISLE and r["category"] == "wellness"]
        if r["category"] != "wellness" or r.get("subs") != subs:
            moved.append(r)
            r["category"], r["subs"] = "wellness", subs
    return moved
