#!/usr/bin/env python3
"""Shopper filters read from what a brand says about a product (owner,
2026-10-10: "For 4C hair", "Fragrance-free", skin-concern chips).

Writes product["attrs"], only the keys that apply:
    {"hair": ["4c", "coils"], "skin": ["acne"], "free": ["fragrance", "sulfate"],
     "scent": ["vanilla", "oud"], "fabric": "cotton"}
Skincare also gets (owner, 2026-11-04, from Sephora's Filter & Sort, "only
have filters that reflect skincare in the skincare category and the ones for
hair in the hair category"):
    {"skintype": ["oily", "combination"], "ingredient": ["niacinamide"],
     "form": ["serum"], "pack": ["mini"], "spf": ["high"]}
Skin fields are tagged on skincare only, hair on hair only, "free" on both.
Hair also gets what it needs help with, and baby the three skin concerns a
parent filters on (owner, 2026-11-22: "a filter for products that are good
for eczema ... skin sensitivity filters for skin products, hair texture or
sensitivities for hair products"):
    hair: {"hairneed": ["sensitive_scalp", "dandruff", "breakage"]}, and
          "fine", "thick", "low_porosity", "high_porosity" among "hair"
    baby: {"skin": ["eczema", "sensitive", "dryness"], "free": [...]}
These are the brand's words about who a product is for, never a claim of
ours that it treats anything.

A filter must not lie, so each value needs the brand's own words:
- free: only an explicit "fragrance-free" / "free of sulfates" / "no parabens"
  (vegan: the word itself, not "non-vegan"). Never inferred from an
  ingredient list.
- hair, skin: the title, type or tags name it, or the description says the
  product is for it ("for 4C hair", "acne-prone skin", "fades dark spots").
  A bare mention elsewhere in a description ("unlike gels that flake on 4C
  hair...") is only a candidate; TypeSafe's Jev is asked about that one value
  and the cached answer must be a yes at p >= 0.9. "All hair types" is not
  read as any one type.
- skintype: "for oily and combination skin", "all skin types" in a FOR
  context, or the title/type/tags.
- ingredient: the title/type/tags or description name it (not "free of",
  "without", "unlike", "alternative to" it), or the brand's published
  ingredient list (catalog/ingredients.json) has it. Lactic acid counts from
  the list only in its first twelve entries (later it is a pH adjuster).
- form, pack: the title or type ("Cleansing Balm", "Travel Size", "Gift Set").
- spf: an "SPF 50" in the title, type or tags, or a "broad spectrum SPF 30"
  claim; high is over 30, low is 30 and under.
- scent: notes from the title or a "notes:" / "scent:" passage, at most 3.
- fabric: the largest fibre in a stated composition (fiber_badge.composition).

Verdicts are cached in catalog/jev_attributes.json keyed by what Jev saw, so
the build never needs the key and a product is asked about once. With no
TYPESAFE_API_KEY the rules alone decide (candidates stay unset).

    python3 catalog/attributes.py            # rules + cached verdicts, rewrite catalog
    python3 catalog/attributes.py --ask      # also ask Jev about new candidates (<= 3,000)
    python3 catalog/attributes.py --dry-run  # count, write nothing
"""
import argparse
import hashlib
import html
import json
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fiber_badge as fb  # noqa: E402
from catalog_io import write_catalog  # noqa: E402

CATALOG = HERE.parent / "Marracat" / "Resources" / "catalog.json"
VERDICTS = HERE / "jev_attributes.json"
MIN_P = 0.9
MAX_CALLS = 3000

BEAUTY = {"hair", "skincare", "makeup", "fragrance", "baby", "wellness"}
SCENTED = BEAUTY | {"home", "household"}

# value -> pattern naming it (as a word)
HAIR = {
    "3c": r"3c", "4a": r"4a", "4b": r"4b", "4c": r"4c",
    "coils": r"coil(?:s|y)?|kinky(?:[- ]coily)?",
    "locs": r"locs|dread ?locks?|sister ?locks?|loc (?:gel|butter|oil|spray|soak|wash|cream|foam|mousse)|retwist",
    "curls": r"curls|curly|curl (?:cream|custard|gel|defin\w*|enhanc\w*|activator|pudding|milk|smoothie|mousse)",
    "waves": r"wavy|360 waves|waves? (?:pomade|brush|butter|cream)",
    "straight": r"straight hair|relaxed hair|silk press",
    # Texture and porosity, beside the curl patterns ("thin hair", not "thinning hair").
    "fine": r"fine hair|thin hair|fine[,/ ]+(?:or |and )?(?:thin|limp|flat) hair",
    "thick": r"thick hair|coarse hair|thick[,/ ]+(?:or |and )?(?:coarse|dense) hair",
    "low_porosity": r"low[- ]porosity",
    "high_porosity": r"high[- ]porosity",
}
# What the hair or scalp needs help with ("Hair & scalp concern").
HAIRNEED = {
    "sensitive_scalp": r"sensitive scalps?|scalp sensitivity|irritated scalps?",
    "dandruff": r"dandruff|anti-?dandruff|seborrh?oeic dermatitis|seborrh?eic dermatitis|flaky scalps?|scalp flak(?:es|ing)",
    "dry_scalp": r"dry scalps?|itchy scalps?|scalp itch(?:ing|iness)?|dry,? itchy scalps?",
    "damage": r"damaged hair|hair damage|breakage|split ends|bond[- ](?:repair\w*|build\w*)|heat damage",
    "thinning": r"thinning hair|hair thinning|hair loss|hair growth|regrowth|thin(?:ning)? edges",
    "frizz": r"frizz(?:y)?|anti-?frizz",
    # "Dry hair" alone is as often an instruction ("apply to wet or dry
    # hair") as a need, so this one carries its own claim words.
    "dry_hair": (r"brittle hair|dry,? (?:brittle|damaged|thirsty|dull|parched|coarse) hair|dry (?:or|and|&) (?:damaged|brittle) hair|"
                 r"(?:for|hydrat\w+|moisturi[sz]\w+|nourish\w*|quench\w*|reviv\w+|restor\w+|soften\w*|rescu\w+) (?:very |extremely |your )?dry hair|"
                 r"dry hair (?:types?|shampoo|conditioner|mask|masque|treatment|oil|serum|cream|butter|repair|rescue|remedy|therapy)"),
    "color_treated": r"colou?r[- ]treated|colou?r[- ]safe|colou?red hair",
}
# Values whose pattern already says the product is for it: a mention counts.
SELF_CLAIMING = {"dry_hair"}
# What a hair product is said to do about one of those, on top of FOR.
HAIR_FOR_EXTRA = r"prevents?|repairs?|strengthens?|against|stops?|combats?|relieves?|tames?|controls?|eliminates?|smooths?|restores?|protects?(?: against| from)?|promotes?|supports?|encourages?|stimulates?"
SKIN = {
    "acne": r"acne|breakouts?|blemish(?:es)?|pimples?",
    "dark_spots": r"hyper-?pigment\w*|dark (?:spots?|marks?)|discolou?ration|uneven (?:skin )?tone|melasma",
    "eczema": r"eczema|atopic|psoriasis",
    "dryness": r"dry skin|very dry|dryness|dehydrated skin",
    "oily": r"oily skin|excess oil|shine control",
    "sensitive": r"sensitive skin|for sensitive",
    "aging": r"anti-?aging|anti-?ageing|fine lines|wrinkles?",
    "razor_bumps": r"razor bumps?|razor burn|shav(?:e|ing) bumps?|ingrown hairs?|ingrowns?",
}
# The skin concerns read on baby products: the ones a parent shops by.
BABY_SKIN = ("eczema", "sensitive", "dryness")
SKIN.update({
    "dullness": r"dull(?:ness)?(?: skin| complexion)?|brighten\w*|radiance|lackluster",
    "pores": r"(?:enlarged |visible |clogged )?pores",
    "redness": r"redness|rosacea",
    "dark_circles": r"dark circles|puff(?:iness|y eyes)|under-?eye bags",
    "firmness": r"(?:loss of )?firmness|firming|sagging|elasticity",
    "texture": r"(?:uneven|rough|bumpy) (?:skin )?texture|smooths? (?:skin )?texture|refines? (?:skin )?texture",
})
# Concerns that read as something else without a skin word beside them
# ("brightens your day", a tea "for radiance").
NEEDS_SKIN_WORD = {"dullness", "pores", "redness", "firmness", "texture", "dark_circles"}
SKIN_WORD = re.compile(r"\b(?:skin|complexion|face|facial|eyes?|under-?eye)\b", re.I)
SKIN_TYPES = ["normal", "dry", "oily", "combination", "sensitive", "mature"]
_TYPE_WORD = r"(?:normal|dry|oily|combination|combo|sensitive|mature)"
SKINTYPE_LIST = re.compile(r"(?<![a-z])(" + _TYPE_WORD + r"(?:\s*(?:,|/|&|\bto\b|\band\b|\bor\b)\s*" + _TYPE_WORD
                           + r")*)\s+skin(?:\s+types?)?(?![a-z])", re.I)
ALL_SKIN = re.compile(r"(?<![a-z])all skin types?(?![a-z])", re.I)
# value -> pattern naming the ingredient (as a word), in prose or an INCI list
INGREDIENT = {
    "vitamin_c": r"vitamin c|ascorbic acid|ascorbyl \w+|\w+ ascorbate|ascorbyl",
    "hyaluronic": r"hyaluronic(?: acid)?|\w*hyaluronate",
    "niacinamide": r"niacinamide",
    "retinoid": r"retinol|retinal|retinaldehyde|retinoids?|retinyl \w+|hydroxypinacolone retinoate",
    "bakuchiol": r"bakuchiol",
    "salicylic": r"salicylic acid|bha",
    "aha": r"glycolic acid|lactic acid|mandelic acid|ahas?|alpha[- ]hydroxy acids?",
    "peptides": r"\w*peptides?(?:-\d+)?|matrixyl",
    "ceramides": r"ceramides?(?: \w{1,4})?",
    "squalane": r"squalane",
    "shea": r"shea butter|butyrospermum parkii(?: \(shea\))?(?: butter)?",
    "collagen": r"collagen",
    "centella": r"centella(?: asiatica)?|cica|madecassoside|asiaticoside",
    "azelaic": r"azelaic acid",
    "tranexamic": r"tranexamic acid",
    "kojic": r"kojic acid",
    "sulfur": r"sulfur|sulphur",
    "benzoyl": r"benzoyl peroxide",
    "turmeric": r"turmeric|curcuma longa",
}
NOT_IN = re.compile(r"(?:free (?:of|from)|without|\bno\b|unlike|alternative to|instead of|replaces?|substitute for|"
                    r"don'?t (?:use|mix|combine)|avoid)[\w ,/&-]{0,25}$", re.I)
# value -> pattern in the title or type (Sephora's Formulation)
FORM = {
    "serum": r"serums?|ampoules?|essences?",
    "cream": r"creams?|cr[eè]me",
    "lotion": r"lotions?|milks?|emulsions?",
    "oil": r"(?<!-)oils?(?![- ](?:free|control|absorb\w*))",
    "balm": r"balms?|salves?",
    "butter": r"butters?",
    "gel": r"gels?|gel[- ]cream|jelly|jellies",
    "foam": r"foam(?:ing)?|mousse|lather",
    "mist": r"mists?|sprays?|spritz",
    "mask": r"masks?|masque",
    "scrub": r"scrubs?|polish|exfoliating grains",
    "stick": r"sticks?",
    "bar": r"bar soaps?|soap bars?|bars?",
    "wipes": r"wipes?|pads?|cloths?",
    "powder": r"powders?",
    "toner": r"toners?|tonics?",
}
PACK = {
    "mini": r"minis?|travel[- ]size[d]?|travel|deluxe sample|sample size|trial size|discovery",
    "value": r"value size|jumbo|super[- ]size|family size|mega size|bonus size|value pack",
    "set": r"gift set|sets?|kits?|bundles?|duo|trio|regimen|routine",
    "refill": r"refills?|refill pouch",
}
SPF_RE = re.compile(r"(?<![a-z])spf\s*(\d{1,3})\+?", re.I)
SPF_CLAIM = re.compile(r"broad[- ]spectrum[^.]{0,20}?spf\s*(\d{1,3})", re.I)

# "for", "on", "prone" style contexts that make a description mention a claim
FOR = r"(?:for|on|to|prone|targets?|treats?|fights?|fades?|reduces?|soothes?|calms?|helps?(?: with)?|designed for|made for|ideal for|perfect for|brightens?|minimi[sz]es?|refines?|firms?|tightens?|evens?(?: out)?|revives?|clears?|unclogs?|depuffs?)"
FREE = {
    "fragrance": r"fragrance[- ]free|free (?:of|from) (?:added )?fragrances?|no (?:added )?fragrances?|without (?:added )?fragrances?",
    "sulfate": r"sulfate[- ]free|sulphate[- ]free|free (?:of|from) sul[pf]hates?|no sul[pf]hates?",
    "paraben": r"paraben[- ]free|free (?:of|from) parabens?|no parabens?",
    "silicone": r"silicone[- ]free|free (?:of|from) silicones?|no silicones?",
    "alcohol": r"alcohol[- ]free|free (?:of|from) (?:drying )?alcohols?",
    "cruelty_free": r"cruelty[- ]free|leaping bunny|not tested on animals",
}
# Free-of values that only mean something on skin.
FREE_SKIN_ONLY = {"oil": r"oil[- ]free", "noncomedogenic": r"non-?comedogenic|won'?t clog pores|will not clog pores|does not clog pores"}
VEGAN = re.compile(r"(?<![-\w])(?<!non[- ])(?<!not )vegan\b", re.I)
NOT_VEGAN = re.compile(r"\b(?:non|not)[- ]vegan\b", re.I)
NOTES = ["vanilla", "oud", "sandalwood", "rose", "jasmine", "amber", "bergamot", "lavender", "citrus", "musk",
         "patchouli", "cedar", "cedarwood", "vetiver", "coconut", "tobacco", "leather", "neroli", "fig", "pear",
         "peony", "tonka", "coffee", "honey", "lemongrass", "eucalyptus", "peppermint", "cherry",
         "orange blossom", "tuberose", "ylang", "saffron", "frankincense", "myrrh", "grapefruit", "mandarin",
         "lemon", "lime", "mango", "pineapple", "cocoa", "caramel", "cinnamon", "ginger", "sage", "mint",
         "white tea", "green tea", "iris", "lily", "magnolia", "gardenia", "violet", "pink pepper", "cardamom"]
NOTE_RE = re.compile(r"\b(" + "|".join(sorted(map(re.escape, NOTES), key=len, reverse=True)) + r")\b", re.I)
NOTES_PASSAGE = re.compile(r"(?:(?:top|heart|middle|base) notes?|notes? (?:of|include)|scent(?: notes)?|fragrance notes?|smells? like)\s*[:\-]?\s*(.{0,160})", re.I)


def _clean(s):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s or ""))).strip()


def _strong(p):
    """Title, type and tags: where a brand names what the product is."""
    return _clean(" ".join([p.get("title") or "", p.get("product_type") or "", " ".join(p.get("tags") or [])]))


def _word(pat):
    return re.compile(r"(?<![a-z0-9])(?:" + pat + r")(?![a-z0-9])", re.I)


HAIR_RE = {k: _word(v) for k, v in HAIR.items()}
HAIRNEED_RE = {k: _word(v) for k, v in HAIRNEED.items()}
SKIN_RE = {k: _word(v) for k, v in SKIN.items()}
FREE_RE = {k: _word(v) for k, v in FREE.items()}
FREE_SKIN_RE = {k: _word(v) for k, v in FREE_SKIN_ONLY.items()}
INGREDIENT_RE = {k: _word(v) for k, v in INGREDIENT.items()}
FORM_RE = {k: _word(v) for k, v in FORM.items()}
PACK_RE = {k: _word(v) for k, v in PACK.items()}
ALL_TYPES = re.compile(r"all hair (?:types|textures)", re.I)
HAIR_FOR = FOR[:-1] + "|" + HAIR_FOR_EXTRA + ")"
# "not for", "may cause", "can lead to": the mention after it is a warning.
# ("Leads to fewer ingrowns" and "leads to diminishing of dark spots" are claims.)
NOT_FOR = re.compile(r"(?:\bnot (?:for|recommended|suitable)|\b(?:may|can|could|might) cause|\bcauses?"
                     r"|\bleads? to(?! (?:diminish\w*|fewer|less|reduc\w*|a reduction|fading|the fading|clearer)))\b[\w ,/&-]{0,25}$", re.I)


def _claimed(rx, desc, context=None):
    """The description says the product is for it: a FOR word within a few
    words before the mention, or "<value>-prone" / "<value> hair|skin" after.
    `context` swaps FOR for a wider set of words (HAIR_FOR)."""
    context = context or FOR
    for m in rx.finditer(desc):
        before = desc[max(0, m.start() - 40):m.start()]
        after = desc[m.end():m.end() + 14]
        if NOT_FOR.search(before):
            continue
        if re.search(context + r"\b[\w ,/&-]{0,25}$", before, re.I) or re.match(r"[- ]?(?:prone|hair|skin|types?|textures?)\b", after, re.I):
            return True
    return False


def _stated(rx, desc):
    """A mention that is not a warning, for patterns that carry their own claim."""
    return any(not NOT_FOR.search(desc[max(0, m.start() - 40):m.start()]) for m in rx.finditer(desc))


def _skintypes(text):
    """Skin types a passage names: "oily and combination skin" -> [oily, combination]."""
    out = []
    for m in SKINTYPE_LIST.finditer(text):
        for w in re.findall(_TYPE_WORD, m.group(1), re.I):
            w = "combination" if w.lower() == "combo" else w.lower()
            if w not in out:
                out.append(w)
    return out


def _named(rx, text):
    """The text names it, and not as something left out or compared against."""
    return any(not NOT_IN.search(text[max(0, m.start() - 40):m.start()])
               and not re.match(r"[- ]?free\b", text[m.end():m.end() + 6], re.I)
               for m in rx.finditer(text))


SUN = re.compile(r"\b(?:spf|sunscreen|sun ?screen|sunblock|sun)\b", re.I)
WITH = re.compile(r"\b(?:with|plus|w/)\s|\s\+\s", re.I)


def _form(name):
    """The form word a product name ends on, ignoring ones after "with"
    ("Soap with Neem Oil" -> None, "Shea Butter Infused Body Lotion" -> lotion)."""
    head = WITH.split(re.sub(r"\(.*?\)|\|.*$| - .*$", " ", name))[0]
    best, at = None, -1
    for k, rx in FORM_RE.items():
        for m in rx.finditer(head):
            if m.start() > at:
                best, at = k, m.start()
    if best and re.search(r"\bsoaps?\b", head[at:], re.I) and best != "bar":
        return None
    return best


def _inci_has(value, rx, inci):
    if value == "aha":
        top = ", ".join(re.split(r",\s*", inci)[:12])
        return bool(re.search(r"glycolic|mandelic", inci, re.I) or re.search(r"lactic acid", top, re.I))
    return bool(rx.search(inci))


def rules(p, inci=None):
    """-> (attrs, candidates): attrs the brand's words settle, and
    [(field, value)] mentioned only in passing (for Jev to confirm).
    `inci` is the brand's published ingredient list, when we have it."""
    cat = p.get("category")
    strong, desc = _strong(p), _clean(p.get("description"))
    attrs, cand = {}, []
    if cat == "hair":
        hair = []
        for k, rx in HAIR_RE.items():
            if rx.search(strong) or _claimed(rx, desc):
                hair.append(k)
            elif rx.search(desc) and not ALL_TYPES.search(desc):
                cand.append(("hair", k))
        if hair:
            attrs["hair"] = hair
        need = []
        for k, rx in HAIRNEED_RE.items():
            if rx.search(strong) or _claimed(rx, desc, HAIR_FOR) or (k in SELF_CLAIMING and _stated(rx, desc)):
                need.append(k)
            elif rx.search(desc):
                cand.append(("hairneed", k))
        if need:
            attrs["hairneed"] = need
    if cat == "baby":
        skin = []
        for k in BABY_SKIN:
            rx = SKIN_RE[k]
            if rx.search(strong) or _claimed(rx, desc):
                skin.append(k)
            elif rx.search(desc):
                cand.append(("skin", k))
        if skin:
            attrs["skin"] = skin
    if cat == "skincare":
        skin = []
        for k, rx in SKIN_RE.items():
            if k in NEEDS_SKIN_WORD:
                near = lambda t: any(SKIN_WORD.search(t[max(0, m.start() - 40):m.end() + 40]) for m in rx.finditer(t))
                if (rx.search(strong) and near(strong)) or (_claimed(rx, desc) and near(desc)):
                    skin.append(k)
                continue
            if rx.search(strong) or _claimed(rx, desc):
                skin.append(k)
            elif rx.search(desc):
                cand.append(("skin", k))
        if skin:
            attrs["skin"] = skin
        # Skin type: named in the title/type/tags, or in a FOR context.
        types = _skintypes(strong)
        for m in SKINTYPE_LIST.finditer(desc):
            if re.search(FOR + r"\b[\w ,/&-]{0,25}$", desc[max(0, m.start() - 40):m.start()], re.I):
                types += [t for t in _skintypes(m.group(0)) if t not in types]
        if ALL_SKIN.search(strong) or any(re.search(FOR + r"\b[\w ,/&-]{0,25}$", desc[max(0, m.start() - 40):m.start()], re.I)
                                          for m in ALL_SKIN.finditer(desc)):
            types.append("all")
        if types:
            attrs["skintype"] = [t for t in SKIN_TYPES + ["all"] if t in types]
        ingredients = [k for k, rx in INGREDIENT_RE.items()
                       if _named(rx, strong) or _named(rx, desc) or (inci and _inci_has(k, rx, inci))]
        if ingredients:
            attrs["ingredient"] = ingredients
        pack = [k for k, rx in PACK_RE.items() if rx.search(p.get("title") or "")]
        if pack:
            attrs["pack"] = pack
        # One form: the last form word in the title ("Body Oil Bar" is a bar,
        # "Soap with Neem Oil" names no form), else the product type's.
        # A set holds several, so it gets none.
        if "set" not in pack:
            form = _form(p.get("title") or "") or _form(p.get("product_type") or "")
            if form:
                attrs["form"] = [form]
        spf = [int(m.group(1)) for m in SPF_RE.finditer(strong)]
        if SUN.search(strong):
            spf += [int(m.group(1)) for m in SPF_CLAIM.finditer(desc)]
        spf = [n for n in spf if 2 <= n <= 100]
        if spf:
            attrs["spf"] = ["high" if max(spf) > 30 else "low"]
    if cat in ("hair", "skincare", "baby"):
        text = f"{strong} {desc}"
        free = [k for k, rx in FREE_RE.items() if rx.search(text)]
        if cat == "skincare":
            free += [k for k, rx in FREE_SKIN_RE.items() if rx.search(text)]
        if VEGAN.search(text) and not NOT_VEGAN.search(text):
            free.append("vegan")
        if free:
            attrs["free"] = free
    if cat in SCENTED:
        notes = []
        sources = [p.get("title") or ""] + [m.group(1) for m in NOTES_PASSAGE.finditer(desc)]
        for s in sources:
            for m in NOTE_RE.finditer(s):
                n = m.group(1).lower()
                n = "cedar" if n == "cedarwood" else n
                if n not in notes:
                    notes.append(n)
        if notes:
            attrs["scent"] = notes[:3]
    if cat == "clothing":
        comp = fb.composition(fb.text_of(p))
        if comp and comp.get("parts") and not comp.get("varies"):
            pct, name, _cls = max(comp["parts"], key=lambda x: x[0])
            if pct >= 50:
                attrs["fabric"] = name.replace("organic ", "")
    return attrs, cand


QUESTION = {
    "hair": "Does the brand say this product is made for {label} hair?",
    "skin": "Does the brand say this product is for {label}?",
    "hairneed": "Does the brand say this product is for {label}?",
}
LABEL = {"3c": "3C", "4a": "4A", "4b": "4B", "4c": "4C", "coils": "coily or kinky", "locs": "locs (dreadlocks)",
         "curls": "curly", "waves": "wavy or 360-wave", "straight": "straight or relaxed",
         "acne": "acne-prone skin or breakouts", "dark_spots": "dark spots or hyperpigmentation",
         "eczema": "eczema-prone skin", "dryness": "dry skin", "oily": "oily skin", "sensitive": "sensitive skin",
         "aging": "signs of aging such as fine lines", "dullness": "dull skin (brightening)",
         "pores": "visible or clogged pores", "redness": "redness or irritation", "dark_circles": "dark circles or puffy eyes",
         "firmness": "loss of firmness", "texture": "uneven skin texture",
         "razor_bumps": "razor bumps or ingrown hairs",
         "fine": "fine or thin", "thick": "thick or coarse", "low_porosity": "low-porosity", "high_porosity": "high-porosity",
         "sensitive_scalp": "a sensitive scalp", "dandruff": "dandruff or a flaky scalp", "dry_scalp": "a dry or itchy scalp",
         "damage": "damaged hair or breakage", "thinning": "thinning hair or hair growth", "frizz": "frizzy hair",
         "dry_hair": "dry or brittle hair", "color_treated": "colour-treated hair"}


def seen_key(p, field, value):
    text = f"{field}|{value}|{p.get('title')}|{p.get('product_type')}|{(p.get('description') or '')[:900]}"
    return hashlib.sha256(text.encode()).hexdigest()[:20]


def load_cache():
    return json.loads(VERDICTS.read_text()) if VERDICTS.exists() else {}


def confirmed(cache, p, field, value):
    v = cache.get(seen_key(p, field, value))
    return v is not None and v >= MIN_P


def load_inci():
    """Published ingredient lists by product URL (catalog/ingredient_lists.py)."""
    path = HERE / "ingredients.json"
    if not path.exists():
        return {}
    return {k: v for k, v in json.loads(path.read_text()).items() if isinstance(v, str)}


def annotate(products, cache, inci=None):
    """Sets product["attrs"]; returns {value: count} and the open candidates."""
    counts, open_cands = {}, []
    inci = inci or {}
    for p in products:
        attrs, cand = rules(p, inci.get(p.get("url")))
        for field, value in cand:
            if confirmed(cache, p, field, value):
                attrs.setdefault(field, []).append(value)
            elif seen_key(p, field, value) not in cache:
                open_cands.append((p, field, value))
        if attrs:
            p["attrs"] = attrs
            for field, vals in attrs.items():
                for v in (vals if isinstance(vals, list) else [vals]):
                    counts[f"{field}:{v}"] = counts.get(f"{field}:{v}", 0) + 1
        else:
            p.pop("attrs", None)
    return counts, open_cands


async def _ask(todo):
    import asyncio
    from typesafe_sdk import AsyncTypeSafeClient, Noul
    sem = asyncio.Semaphore(1)  # sequential: one call at a time (owner, 2026-10-11)
    out, tokens, failed = {}, 0, 0

    async def one(client, p, field, value):
        nonlocal tokens, failed
        async with sem:
            try:
                r = await client.system_one(
                    state={"product": p.get("title") or "", "product_type": p.get("product_type") or "",
                           "description": _clean(p.get("description"))[:900]},
                    questions={"q": Noul(instructions=QUESTION[field].format(label=LABEL[value]),
                                         criteria={"true": "The product text says it is for this",
                                                   "false": "It is mentioned only in passing, as a contrast, or not at all"})})
            except Exception as e:  # noqa: BLE001 — one product must not sink the run
                failed += 1
                print(f"  ! {p['id']} {field}:{value}: {type(e).__name__}", file=sys.stderr)
                return
        tokens += r.usage.input_tokens
        out[seen_key(p, field, value)] = round(float(r.answers["q"].noul), 3)

    async with AsyncTypeSafeClient() as client:
        await asyncio.gather(*(one(client, p, f, v) for p, f, v in todo))
    return out, tokens, failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ask", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-calls", type=int, default=MAX_CALLS)
    args = ap.parse_args()
    catalog = json.loads(CATALOG.read_text())
    cache = load_cache()
    inci = load_inci()
    counts, todo = annotate(catalog["products"], cache, inci)
    print(f"attributes: {sum(1 for p in catalog['products'] if p.get('attrs'))} products tagged; "
          f"{len(todo)} unconfirmed mentions")
    if args.ask and todo and os.environ.get("TYPESAFE_API_KEY") and not args.dry_run:
        import asyncio
        todo = todo[:args.max_calls]
        got, tokens, failed = asyncio.run(_ask(todo))
        cache.update(got)
        VERDICTS.write_text(json.dumps(cache, indent=0, sort_keys=True) + "\n")
        print(f"asked {len(got)}, failed {failed}, {tokens} input tokens (~${tokens * 0.042 / 1e6:.4f}); "
              f"yes: {sum(1 for v in got.values() if v >= MIN_P)}")
        counts, _ = annotate(catalog["products"], cache, inci)
    for k in sorted(counts, key=lambda k: -counts[k])[:120]:
        print(f"  {k:24} {counts[k]}")
    if not args.dry_run:
        write_catalog(CATALOG, catalog)


if __name__ == "__main__":
    main()
