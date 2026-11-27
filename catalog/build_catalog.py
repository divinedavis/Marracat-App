#!/usr/bin/env python3
"""Build Marracat/Resources/catalog.json from each brand's public Shopify feed.

Every brand in brands.json with "shopify": true is read from
https://<domain>/products.json — Shopify's public, keyless product feed — and
each product is sorted into one app category by keyword scoring.

Politeness: one request at a time, DELAY seconds apart, at most MAX_PRODUCTS
products per store, a real browser User-Agent, and each store fetched once even
when two brands share it (Fenty Beauty / Fenty Hair).

Stdlib only (Homebrew Python has no `requests`).  Usage:
    python3 catalog/build_catalog.py            # fetch + write
    python3 catalog/build_catalog.py --cached   # re-categorise from the last fetch
"""
import base64
import hashlib
import html
import json, subprocess
import re
import ssl
import sys
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fx  # noqa: E402  dollar rates for non-dollar brands
from taxonomy import flat_subcategories, subcategories_of, with_added_aisles   # noqa: E402
from catalog_io import products_of_brands, write_catalog  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BRANDS = ROOT / "catalog" / "brands.json"
CACHE = ROOT / "catalog" / ".cache"
OUT = ROOT / "Marracat" / "Resources" / "catalog.json"
COMPACT_OUT = ROOT / "Marracat" / "Resources" / "catalog-compact.json"
REPORT = ROOT / "catalog" / "report.md"

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
PAGE_SIZE = 250
WOO_PAGE_SIZE = 100
# Up to 4,000 products a store (owner, 2026-10-02). At 1,000 (four pages) 15
# stores were cut off, God Ain't Petty at a quarter of its 3,962; before
# that, 37 stores hit a two-page ceiling.
MAX_PRODUCTS = 4_000
MAX_PAGES = MAX_PRODUCTS // PAGE_SIZE
# How deep we go into a brand's store. Everything the store has in stock: a
# brand we carry is a brand we carry whole. This is affordable because what the
# app and the site read is the compact catalog — no descriptions, one image,
# variants only where there is a single one — which is ~470 bytes a product
# against ~2,000 full fat. See publish_snapshots.py and /api/products/:id.
PER_BRAND_CAP = 100_000
DELAY = 1.5
FETCH_WORKERS = 8
MAX_IMAGES = 6

# The order shoppers see departments in, in the app and on the website. Beauty
# leads, then bags (owner, 2026-10-04). Placement doesn't depend on it:
# categorize() scores every department and keeps the highest.
CATEGORIES = [
    {"id": "skincare", "name": "Skincare", "symbol": "face.smiling"},
    {"id": "makeup", "name": "Makeup", "symbol": "paintbrush.pointed"},
    {"id": "hair", "name": "Hair Care", "symbol": "scissors"},
    {"id": "bags", "name": "Bags", "symbol": "handbag"},
    {"id": "fragrance", "name": "Fragrance", "symbol": "drop"},
    {"id": "clothing", "name": "Clothing", "symbol": "tshirt"},
    {"id": "jewelry", "name": "Jewelry", "symbol": "sparkle"},
    {"id": "accessories", "name": "Accessories", "symbol": "eyeglasses"},
    {"id": "home", "name": "Candles & Home", "symbol": "flame"},
    # The departments Amazon runs that an independent-brand marketplace can
    # plausibly stock. A category with no products never ships (see the app's
    # `categories`), so an aspirational one costs nothing until a brand fills it.
    {"id": "household", "name": "Household Essentials", "symbol": "washer"},
    {"id": "wellness", "name": "Health & Wellness", "symbol": "heart.text.square"},
    {"id": "grocery", "name": "Grocery & Gourmet", "symbol": "basket"},
    {"id": "baby", "name": "Baby & Kids", "symbol": "figure.and.child.holdinghands"},
    {"id": "pets", "name": "Pet Supplies", "symbol": "pawprint"},
    {"id": "toys", "name": "Toys & Games", "symbol": "teddybear"},
    {"id": "sports", "name": "Sports & Outdoors", "symbol": "figure.run"},
    {"id": "books", "name": "Books & Media", "symbol": "books.vertical"},
    {"id": "crafts", "name": "Arts & Crafts", "symbol": "paintpalette"},
    {"id": "office", "name": "Office & School", "symbol": "paperclip"},
    {"id": "tools", "name": "Tools & Home Improvement", "symbol": "wrench.and.screwdriver"},
    {"id": "electronics", "name": "Electronics", "symbol": "headphones"},
    {"id": "shoes", "name": "Shoes", "symbol": "shoeprints.fill"},
    {"id": "luggage", "name": "Luggage & Travel", "symbol": "suitcase"},
    {"id": "garden", "name": "Garden & Outdoor", "symbol": "leaf"},
    {"id": "auto", "name": "Automotive", "symbol": "car"},
    {"id": "music", "name": "Musical Instruments", "symbol": "guitars"},
    {"id": "party", "name": "Party & Gifting", "symbol": "gift"},
    {"id": "alcohol", "name": "Wine & Spirits", "symbol": "wineglass"},
]
CATEGORIES_BY_ID = {c["id"]: c["name"] for c in CATEGORIES}

# Matched as whole words (plural "s" allowed). Order is irrelevant — scoring decides.
KEYWORDS = {
    "bags": ["bag", "tote", "duffle", "duffel", "backpack", "crossbody", "clutch", "purse",
             "handbag", "satchel", "shopper", "pouch", "sling", "cuatote", "weekender", "baguette",
             "top handle", "shoulder bag"],
    "fragrance": ["perfume", "parfum", "eau de parfum", "eau de toilette", "fragrance", "cologne",
                  "body mist", "hair mist", "extrait", "rollerball", "discovery set",
                  "sampler", "scent", "edp", "perfume oil", "travel spray"],
    "home": ["candle", "diffuser", "room spray", "wax melt", "incense", "reed", "home fragrance", "matches"],
    "skincare": ["serum", "cleanser", "moisturizer", "moisturiser", "cream", "balm", "mask", "masque",
                 "face masque", "deodorant", "antiperspirant", "toner",
                 "sunscreen", "spf", "exfoliant", "exfoliator", "skincare", "skin care", "face oil",
                 "body butter", "body wash", "lotion", "body oil", "scrub", "retinol", "hydrating",
                 "dark spot", "hyperpigmentation"],
    "makeup": ["lip", "lipstick", "gloss", "lip gloss", "foundation", "concealer", "blush", "bronzer",
               "highlighter", "mascara", "eyeliner", "eyeshadow", "powder", "primer", "palette",
               "brow", "makeup", "setting spray", "lip liner", "lip oil", "complexion", "brush",
               "sponge", "stick"],
    "hair": ["shampoo", "conditioner", "hair", "scalp", "leave-in", "detangler", "curl", "edges",
             "hair towel", "t-shirt towel", "microfiber towel",
             "hair oil", "hair mask", "styler"],
    "jewelry": ["necklace", "chain", "ring", "bracelet", "earring", "pendant", "grillz", "anklet",
                "waist bead", "waist beads", "wire wrap", "crystal pendant", "body chain",
                "jewelry", "jewellery", "cuban", "stud", "hoop", "tennis chain", "rope chain"],
    "clothing": ["shirt", "jersey", "bra", "bralette", "tee", "t-shirt", "hoodie", "sweatshirt", "crewneck", "jacket", "pants",
                 "shorts", "dress", "top", "skirt", "jeans", "sweatpants", "joggers", "bodysuit", "tank",
                 "sweater", "cardigan", "coat", "vest", "romper", "jumpsuit", "legging", "trouser",
                 "polo", "jersey", "denim", "apparel", "tracksuit", "sweats", "knit", "zip-up", "quarter zip",
                 "pullover", "cargo", "overshirt", "button-up", "button down", "henley", "lounge set",
                 "sweatsuit"],
    "household": ["laundry detergent", "detergent", "fabric softener", "dryer sheet", "stain remover",
                  "all purpose cleaner", "surface cleaner", "dish soap", "dishwasher", "cleaning spray",
                  "disinfectant", "floor cleaner", "glass cleaner", "trash bag", "paper towel",
                  "toilet paper", "sponge", "mop", "broom", "air freshener", "laundry pod",
                  "wool dryer ball", "cleaning kit", "hand soap refill", "bleach", "fabric shaver", "lint remover"],
    "wellness": ["supplement", "vitamin", "multivitamin", "probiotic", "collagen", "elderberry",
                 "herbal tea", "tincture", "adaptogen", "ashwagandha", "sea moss", "gummies",
                 "first aid", "pain relief", "sleep aid", "melatonin", "electrolyte", "immunity",
                 "wellness shot", "menopause", "fertility", "prenatal", "sexual wellness", "lubricant",
                 "condom", "period", "menstrual cup", "thermometer", "pill organizer"],
    "grocery": ["hot sauce", "seasoning", "spice blend", "marinade", "bbq sauce", "syrup",
                "jam", "preserves", "olive oil", "coffee", "coffee bean", "espresso", "loose leaf tea", "raw honey",
                "tea bag", "cocoa", "chocolate bar", "granola", "snack", "chips", "popcorn", "cookie",
                "cake mix", "flour", "grits", "rice", "pasta sauce", "jerky", "protein bar", "salsa"],
    "baby": ["diaper", "wipes", "baby bottle", "pacifier", "swaddle", "onesie", "bib", "teether",
             "stroller", "car seat", "nursery", "crib", "baby lotion", "baby wash", "baby oil",
             "toddler", "sippy cup", "high chair", "baby blanket", "burp cloth", "baby book"],
    "pets": ["dog", "cat", "pet", "leash", "collar", "harness", "pet bed", "dog treat", "cat treat",
             "pet tag", "dog tag", "cat tag",
             "pet shampoo", "litter", "chew toy", "pet bowl", "kibble", "pet grooming", "catnip",
             "dog food", "cat food", "pet carrier"],
    "toys": ["toy", "puzzle", "board game", "card game", "doll", "action figure", "building block",
             "plush", "stuffed animal", "playset", "learning toy", "stem kit", "coloring book",
             "activity book", "flash card", "ride on", "yo-yo", "jump rope"],
    "sports": ["yoga mat", "dumbbell", "kettlebell", "resistance band", "jump rope", "water bottle",
               "gym towel", "foam roller", "basketball", "football", "soccer ball", "golf", "tennis",
               "running belt", "fitness tracker", "camping", "hiking", "cooler", "tent", "sleeping bag",
               "bike", "skateboard", "swim goggles", "workout equipment"],
    "books": ["book", "novel", "memoir", "cookbook", "children's book", "poetry", "journal prompt",
              "workbook", "audiobook", "magazine", "comic", "graphic novel", "coloring book adult",
              "planner book", "devotional", "anthology"],
    "crafts": ["yarn", "crochet", "knitting", "embroidery", "cross stitch", "sewing", "fabric",
               "quilting", "craft kit", "bead kit", "candle making", "soap making", "paint set",
               "sketchbook", "canvas panel", "art print set", "resin", "macrame", "scrapbook",
               "glue gun", "sticker sheet"],
    "office": ["planner", "notebook", "notepad", "pen set", "pencil", "marker", "highlighter",
               "sticky note", "binder", "folder", "desk organizer", "desk mat", "calendar",
               "whiteboard", "stapler", "laptop stand", "mouse pad", "file box", "label maker",
               "index card"],
    "tools": ["tool kit", "screwdriver", "wrench", "hammer", "drill", "tape measure", "spirit level",
              "pliers", "socket set", "work glove", "tool bag", "utility knife", "sandpaper",
              "paint brush set", "caulk", "flashlight", "extension cord", "hardware kit"],
    "electronics": ["headphone", "earbud", "speaker", "bluetooth speaker", "charger", "charging cable",
                    "power bank", "phone case", "airpod case", "phone grip", "screen protector",
                    "laptop sleeve case", "webcam", "ring light", "microphone", "smart watch band",
                    "tablet case", "keyboard", "mouse", "usb hub", "projector", "record player"],
    "shoes": ["sneaker", "shoe", "boot", "heel", "sandal", "loafer", "mule", "slide", "flip flop",
              "slipper", "pump", "oxford shoe", "trainer", "clog", "espadrille", "wedge",
              "shoe care", "insole", "shoelace"],
    "luggage": ["suitcase", "carry-on", "checked bag", "luggage set", "packing cube", "travel pillow",
                "passport holder", "luggage tag", "toiletry case", "garment bag", "travel bottle",
                "duffel luggage", "rolling bag", "travel organizer"],
    "garden": ["planter", "plant pot", "seed packet", "heirloom seed", "garden seed", "seed kit", "garden tool", "watering can", "soil",
               "fertilizer", "plant food", "indoor plant", "succulent", "herb garden", "garden glove",
               "hose", "outdoor rug", "patio", "bird feeder", "wind chime", "solar light"],
    "auto": ["car charger", "car mount", "air freshener car", "steering wheel cover", "seat cover",
             "floor mat car", "car wash", "car wax", "tire shine", "dash cam", "license plate frame",
             "jump starter", "car vacuum", "car organizer"],
    "music": ["guitar", "keyboard piano", "drum", "drumstick", "microphone stand", "midi controller",
              "turntable", "vinyl record", "ukulele", "kalimba", "djembe", "shaker", "tambourine",
              "sheet music", "instrument case", "amp"],
    "alcohol": ["wine", "cabernet", "chardonnay", "riesling", "sauvignon", "merlot", "zinfandel",
                "pinot noir", "pinot grigio", "moscato", "rosé", "rose wine", "champagne", "prosecco",
                "sparkling wine", "red blend", "white blend", "vintage bottle", "whiskey", "whisky",
                "bourbon", "rye whiskey", "scotch", "rum", "tequila", "mezcal", "vodka", "gin",
                "cognac", "brandy", "liqueur", "aperitif", "spirits", "distillery", "wine club",
                "wine bundle", "750ml", "sommelier"],
    "party": ["balloon", "party decoration", "banner", "gift wrap", "gift wrapping", "wrapping paper",
              "gift bag",
              "greeting card", "wedding card", "anniversary card", "sympathy card", "thank you card",
              "birthday card", "holiday card", "card set", "note card", "invitation", "party favor",
              "cake topper", "confetti", "tableware set", "gift box", "gift set", "party hat",
              "centerpiece"],
    "accessories": ["hat", "cap", "beanie", "bucket hat", "snapback", "headwear", "socks", "wallet", "keychain", "key chain", "scarf",
                    "sunglasses", "belt", "phone case", "strap", "watch strap", "watch band", "charm",
                    "bandana", "durag", "bonnet", "barrette", "hair clip", "scrunchie", "card holder",
                    "gloves", "umbrella", "notebook", "lanyard", "pin"],
}

# Never list these: store utilities, not products.
SKIP = re.compile(r"gift ?card|e-?gift|gift certificate|sponsorship|shipping protection|\broute\b|"
                  r"package protection|insurance|donation|tip\b|custom order|deposit|test product|"
                  r"do not purchase|promo_item|bundle builder|build your own|paint ?& ?sip|"
                  r"\bworkshop\b|\bticket\b|\brsvp\b|\bclass\b|"
                  # Trade listings a shopper can't use: they surfaced once the
                  # handle lists stopped hiding everything a brand also sells.
                  r"\bwholesale\b|mystery box|\bdisplay unit\b|"
                  # Checkout add-ons (2026-10-30, Big Mouth's protection plans):
                  # a warranty or a wrap service, not wrapping paper.
                  r"protection plan|\bwarranty\b|^(upgraded |new boxed )?gift wrap(ping)?( service)?$", re.I)

def _pattern(keyword):
    """Whole words, plural allowed; a multi-word keyword matches as a phrase."""
    return re.compile(r"\b" + r"[\s\-]+".join(re.escape(w) for w in keyword.split()) + r"(?:s|es)?\b", re.I)


_patterns = {cat: [(k, _pattern(k)) for k in kws] for cat, kws in KEYWORDS.items()}

# Words that read as one category but mean another thing here: calf hair is a
# leather, a top handle is a bag, and a hair clip is an accessory, not hair care.
DISQUALIFY = {
    "hair": [_pattern("calf hair"), _pattern("horse hair"), _pattern("pony hair"),
             _pattern("hair clip"), _pattern("hair barrette"), _pattern("hair pin"),
             _pattern("hair tie"), _pattern("hair band"), _pattern("hair strap")],
    "clothing": [_pattern("top handle"), _pattern("bag top")],
    "skincare": [_pattern("lip butter"), _pattern("body bag")],
    # Crochet hair is an extension, a drum major leads a band, and intimate
    # wipes are not baby wipes.
    "music": [_pattern("drum major"), _pattern("drumline"), _pattern("drum majorette")],
    "baby": [_pattern("intimate wipes"), _pattern("feminine wipes"), _pattern("baby blue"),
             _pattern("baby pink"), _pattern("baby hair")],
    "tools": [_pattern("gift certificate"), _pattern("sponsorship level")],
    # "Jumped the Broom" is a wedding, not a cleaning aisle.
    "household": [_pattern("jumped the broom"), _pattern("broom wedding")],
    # Barware is homeware, and a rose oil is not a rosé.
    "alcohol": [_pattern("wine glass"), _pattern("wine tumbler"), _pattern("wine opener"),
                _pattern("wine bag"), _pattern("wine rack"), _pattern("rose water"),
                _pattern("rose oil"), _pattern("rose quartz"), _pattern("wine stopper"),
                _pattern("wine charm")],
    # A pet brand's human hoodie is clothing; "in heels" names a lipstick shade,
    # not a shoe; a fabric shaver is a laundry tool, not a craft supply.
    "pets": [_pattern("hoodie"), _pattern("t-shirt"), _pattern("sweatshirt"), _pattern("unisex tee")],
    "shoes": [_pattern("in heels"), _pattern("heels lipstick")],
    "crafts": [_pattern("crochet hair"), _pattern("crochet braid"), _pattern("knotless"),
               _pattern("fabric shaver"), _pattern("fabric softener"), _pattern("fabric refresher")],
}


# Pet Supplies is the one department whose keywords are mostly what a product
# is about, not what it is. A record called "Diamond Dogs", a "Birthday Cat
# Card", a "Best Dog Mom Sticker" and a shirt with a collar all carry a pet
# word and none is for a pet (a shopper browsing collars in Pet Supplies met a
# Telfar "Collar T", 2026-11-25; 54 records, cards, prints and stickers sat
# there with it). So outside a pet brand:
#   - "collar" and "harness" belong to shirts, necklaces and fashion first, and
#     count only beside an animal word ("Dog Collar");
#   - "dog", "cat" and "pet" in a title count only when the merchant's own
#     product type says pets too, or the title goes on to name something a pet
#     uses ("Dog Bandana", "Pet Refresh Spray", "Pet House").
# Words that are goods by name ("leash", "catnip", "pet bowl", "dog treat")
# place a product as before, and a pet brand's own products are untouched.
PET_SUBJECTS = {"dog", "cat", "pet"}
PET_BORROWED = {"collar", "harness"}
_PET_ANIMAL = r"(?:dog|doggie|doggy|pup|puppy|puppie|cat|kitty|kitten|pet)s?(?:['\u2019]s)?"
# What may follow the animal, at most one word later ("Pet Refresh Spray").
# Not "eye", "mom" and the like: a cat eye brush is makeup.
_PET_GOODS = re.compile(
    r"\b" + _PET_ANIMAL + r"[\s/&,\-]+"
    r"(?:(?!(?:eyes?|moms?|mamas?|dads?|lady|ladies|lovers?|people|person|themed?|print|shaped?)\b)[\w'\u2019]+[\s/&,\-]+)?"
    r"(?:beds?|bandann?as?|bowls?|feeders?|houses?|collars?|leash(?:es)?|leads?|harness(?:es)?|"
    r"toys?|treats?|food|chews?|shampoos?|conditioners?|wash|sprays?|colognes?|perfumes?|balms?|"
    r"wipes|brush(?:es)?|combs?|blankets?|sweaters?|coats?|raincoats?|costumes?|clothes|clothing|"
    r"apparel|carriers?|crates?|kennels?|tags?|pods?|placemats?|mats?|accessor(?:y|ies)|supplies|"
    r"bow ?ties?|grooming|supplements?|strollers?|scratchers?|litter|cushions?)\b", re.I)


def names_pet_goods(product_type, title, bare_words=False):
    """Do the type and title name something for a pet, or only mention one?
    `bare_words` is the rule before 2026-11-25: any pet keyword was enough."""
    pats = _patterns["pets"]
    in_type = {k for k, p in pats if p.search(product_type)}
    hits = in_type | {k for k, p in pats if p.search(title)}
    if bare_words or hits - PET_SUBJECTS - PET_BORROWED:
        return bool(hits)
    if not hits & PET_SUBJECTS:
        return False                     # a collar or a harness, nobody's pet
    return bool(in_type & PET_SUBJECTS) or bool(_PET_GOODS.search(title))


def categorize(product, brand, bare_pet_words=False):
    """Score each category from product_type (x3), title (x2) and tags (x0.5),
    counting a longer keyword for more ("top handle" beats "top"), nudge toward
    the brand's home category, fall back to it when nothing hits."""
    fields = [(product.get("product_type") or "", 3.0), (product.get("title") or "", 2.0),
              (" ".join(product.get("tags") or []) if isinstance(product.get("tags"), list)
               else product.get("tags") or "", 0.5)]
    scores = {}
    for cat, pats in _patterns.items():
        s = 0.0
        named = False   # did the product type or title say so, or only a tag?
        for i, (text, w) in enumerate(fields):
            if not text:
                continue
            best = max((len(k.split()) for k, p in pats if p.search(text)), default=0)
            if best:
                s += w * (1 + 0.4 * (best - 1))
                named = named or i < 2
        # A tag on its own is too noisy to place a product — brands tag a mug
        # "coffee" and a wall clock "baby".
        if not named:
            s = 0.0
        if s and any(p.search(f"{fields[0][0]} {fields[1][0]}") for p in DISQUALIFY.get(cat, [])):
            s = 0.0
        # Wine, champagne, merlot and burgundy are colours as often as they are
        # drinks — a "Wine Red" slap and a stemware set both match. Only a brand
        # that actually sells alcohol can put anything in Wine & Spirits.
        if cat == "alcohol" and brand["category"] != "alcohol":
            s = 0.0
        if s and cat == "pets" and brand["category"] != "pets" and not names_pet_goods(
                fields[0][0], fields[1][0], bare_pet_words):
            s = 0.0
        if s:
            scores[cat] = s + (1.5 if cat == brand["category"] else 0)
    if not scores:
        return brand["category"]
    return max(scores.items(), key=lambda kv: kv[1])[0]


def frozen_pet_guess(pin, product, brand, handle):
    """A brands.json pin of "pets" that is only an import freezing the old
    bare-word guess (see PET_SUBJECTS): the rules no longer say pets, and
    nobody reviewed it. Such a pin is neither a placement nor a hand pin;
    without this, a nail polish called "Pink Collar Crime" that Jev had moved
    to Makeup would read as pinned to Pet Supplies by hand and go back."""
    return (pin == "pets" and handle not in (brand.get("pinned_handles") or ())
            and categorize(product, brand) != "pets"
            and categorize(product, brand, bare_pet_words=True) == "pets")


def placed(pin, product, brand, handle):
    """Where a product starts: its reviewed pin, else the keyword guess."""
    if not pin or frozen_pet_guess(pin, product, brand, handle):
        return categorize(product, brand)
    return pin


def fetch_curl(url):
    """Same GET over curl. Some stores' bot protection answers urllib with a
    permanent 429 while serving curl fine — the difference is HTTP/2, which
    urllib doesn't speak. Measured 2026-09-22 on thirteen stores at once."""
    out = subprocess.run(["curl", "-sSL", "--max-time", "30", "-A", UA,
                          "-H", "Accept: application/json", url],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise OSError(f"curl failed: {out.stderr.strip()[:120]}")
    return json.loads(out.stdout)


def fetch_json(url, attempts=3):
    """GET JSON, backing off on 429/5xx (stores throw transient 503s)."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code in (429, 403):
                try:
                    return fetch_curl(url)
                except (OSError, json.JSONDecodeError):
                    pass
            if e.code not in (429, 500, 502, 503, 504) or attempt == attempts - 1:
                raise
            wait = int(e.headers.get("Retry-After") or 0) or 5 * 3 ** attempt
            print(f"  … {e.code} on {url}, retrying in {wait}s", file=sys.stderr)
            time.sleep(min(wait, 60))
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            # A failed address lookup or a dropped connection is usually
            # momentary: fetching in parallel, 78 stores "didn't exist" for a
            # moment on 2026-10-05 and resolved fine minutes later. A bad
            # certificate won't fix itself, so that fails at once.
            if "CERTIFICATE" in str(e) or attempt == attempts - 1:
                raise
            time.sleep(3 * 2 ** attempt)


# Domains whose fetch failed this run, and whether the failure looked
# temporary. A brand that answers 429 or 503 for a minute must not vanish from
# the catalog; one whose store is locked (401) or unpaid (402) should.
FETCH_TROUBLE: dict[str, bool] = {}
EMPTY_RETRY_WAIT = 20


def fetch_store(domain):
    """All products from one store, newest pages first, capped at MAX_PAGES."""
    products, seen = [], set()
    for page in range(1, MAX_PAGES + 1):
        url = f"https://{domain}/products.json?limit={PAGE_SIZE}&page={page}"
        try:
            batch = fetch_json(url).get("products", [])
        # ConnectionResetError and friends are OSErrors that never reach
        # urllib's URLError wrapper, so one store dropping the connection
        # used to kill a forty-minute build on its last page.
        except (OSError, json.JSONDecodeError) as e:
            print(f"  ! {url}: {e}", file=sys.stderr)
            code = getattr(e, "code", None)
            FETCH_TROUBLE[domain] = code in (None, 429) or (code is not None and code >= 500)
            break
        if page == 1 and not batch:
            # A busy store can answer 200 with no products: four brands with
            # stock emptied out of the catalog this way (Maya Njie,
            # Afrocenchix, Tawana Simone, Tiannia Barnes; 2026-10-17). Ask
            # again; still empty counts as a temporary failure, so the brand
            # keeps last run's products.
            time.sleep(EMPTY_RETRY_WAIT)
            try:
                batch = fetch_json(url).get("products", [])
            except (OSError, json.JSONDecodeError):
                batch = []
            if not batch:
                print(f"  ! {url}: no products twice, keeping last run's", file=sys.stderr)
                FETCH_TROUBLE[domain] = True
                break
        # A store that changes while it's paged shifts a product onto the
        # next page as well; one copy (2026-11-08: Dobson's "Afrikan Angels"
        # twice under one id broke the app's unique-id check).
        products.extend(p for p in batch if p.get("id") is None or not (p["id"] in seen or seen.add(p["id"])))
        time.sleep(DELAY)
        if len(batch) < PAGE_SIZE:
            break
    return products


def in_registry_order(items, brands, brand_of):
    """`items` (products or brand entries) in the order brands.json lists
    their brands, each brand's own items in the order they came.

    A rescued store's products are added after everything else, and the
    catalog's order is not cosmetic: where two sister stores list the same
    product, the fold (dedupe_products.py) keeps the copy that comes first.
    On 2026-11-26 chriscollins.com answered 429, its 30 products were carried
    through at the end of the list, and every one lost that tie to World of
    Chris Collins: the brand was listed with nothing on its shelf, the web
    tests refused the catalog and the refresh did not publish."""
    place = {b["id"]: i for i, b in enumerate(brands)}
    return sorted(items, key=lambda item: place.get(brand_of(item), len(place)))


def unique_by_id(products):
    """The products with each id once, the first copy kept, and how many went."""
    seen, kept = set(), []
    for p in products:
        if p["id"] not in seen:
            seen.add(p["id"])
            kept.append(p)
    return kept, len(products) - len(kept)


def bigcartel_subdomain(brand):
    """A Big Cartel store's <name>.bigcartel.com name (its feed and cart live
    there even when it shows a custom domain)."""
    return brand.get("bigcartel") or brand["domain"].split(".")[0]


def fetch_store_bigcartel(brand):
    """A Big Cartel store's products in the shape Shopify's products.json uses,
    so normalize() and everything after it treat them alike (owner,
    2026-10-04: add Big Cartel brands). Big Cartel's public feed
    (api.bigcartel.com/<store>/products.json) needs no key; each product's
    "options" are its variants, and an option id is what its cart takes."""
    url = f"https://api.bigcartel.com/{bigcartel_subdomain(brand)}/products.json"
    try:
        raw = fetch_json(url)
    except (OSError, json.JSONDecodeError) as e:
        print(f"  ! {url}: {e}", file=sys.stderr)
        return []
    if not isinstance(raw, list):
        return []
    out = []
    for p in raw:
        cats = [c.get("name", "").strip() for c in p.get("categories") or [] if c.get("name")]
        out.append({
            "id": p["id"],
            "title": p.get("name") or "",
            "handle": p.get("permalink") or str(p["id"]),
            "product_type": cats[0] if cats else "",
            "tags": cats,
            "body_html": p.get("description") or "",
            "published_at": p.get("created_at"),
            "images": [{"src": i.get("secure_url") or i.get("url")} for i in p.get("images") or [] if i.get("url")],
            "variants": [{
                "id": o["id"],
                "title": (o.get("name") or "").strip() or "Default Title",
                "price": str(o.get("price") if o.get("price") is not None else p.get("price")),
                "compare_at_price": None,
                "available": p.get("status") == "active" and not o.get("sold_out"),
            } for o in p.get("options") or []],
        })
    return out


def swell_number(object_id):
    """A catalog variant id for a Swell one. Swell ids are 24-hex ObjectIds
    (96 bits), the app keeps variant ids as Int64 and the website as JS
    numbers, so the catalog carries a 52-bit hash and the Swell ids beside it
    ("swell"); marracat.com/go/swell maps one back to the other."""
    return int(hashlib.sha1(object_id.encode()).hexdigest()[:13], 16)


def shape_swell(p):
    """One Swell product (expanded with its variants) in the shape Shopify's
    products.json uses, so normalize() treats it like the rest. A variant's
    title is its option values in the product's option order, "/"-joined like
    Shopify's, leaving out the placeholder value "blank" some stores fill an
    unused option with. Untracked stock (stock_status null) is buyable."""
    names = {val["id"]: val.get("name") or "" for o in p.get("options") or [] for val in o.get("values") or []}
    order = [val["id"] for o in p.get("options") or [] for val in o.get("values") or []]
    variants = []
    for v in (p.get("variants") or {}).get("results") or []:
        ids = sorted(v.get("option_value_ids") or [], key=lambda i: order.index(i) if i in order else len(order))
        parts = [names.get(i, "").strip() for i in ids]
        title = " / ".join(x for x in parts if x and x.lower() != "blank") or "Default Title"
        price = v.get("price") if v.get("price") is not None else p.get("price")
        variants.append({
            "id": swell_number(v["id"]),
            "swell": v["id"],
            "title": title,
            "price": str(price) if price is not None else None,
            "compare_at_price": None,
            "available": v.get("stock_status") != "out_of_stock" and p.get("stock_status") != "out_of_stock",
        })
    if not variants and p.get("price") is not None:  # no options: the product is its one variant
        variants.append({"id": swell_number(p["id"]), "swell": None, "title": "Default Title",
                         "price": str(p["price"]), "compare_at_price": None,
                         "available": p.get("stock_status") != "out_of_stock"})
    slot = ((p.get("attributes") or {}).get("slot") or {}).get("value")
    return {
        "id": p["id"],
        "swell_product": p["id"],
        "title": p.get("name") or "",
        "handle": p.get("slug") or p["id"],
        "product_type": slot if isinstance(slot, str) else "",
        "tags": [t for t in p.get("tags") or [] if isinstance(t, str)],
        "body_html": p.get("description") or "",
        "published_at": p.get("date_created"),
        "images": [{"src": i["file"]["url"]} for i in p.get("images") or [] if (i.get("file") or {}).get("url")],
        "variants": variants,
        # Shopify's shape, so option_names() reads both alike.
        "options": [{"name": o.get("name") or "", "values": [v.get("name") or "" for v in o.get("values") or []]}
                    for o in p.get("options") or [] if o.get("variant", True)],
    }


def option_names(p):
    """What the store calls each option, in variant-title order ("Color",
    "Size"), so a product page can say "Color: Black" rather than "Option:
    Black" (owner, 2026-10-16). Leaves out Shopify's "Title" (a product
    without options) and an option whose only value is a placeholder, as
    variant titles do (shape_swell); [] when there is nothing to name."""
    names = []
    for o in p.get("options") or []:
        if not isinstance(o, dict):
            continue
        name = html.unescape(str(o.get("name") or "")).strip()
        values = [str(v).strip().lower() for v in o.get("values") or []]
        if not name or name.lower() == "title" or (values and all(v in ("blank", "default title") for v in values)):
            continue
        names.append(name[:30])
    return names[:3]


def fetch_store_swell(brand):
    """A Swell store's products through its storefront API (owner, 2026-10-10:
    Yeezy runs Swell). The public key is the one the store's own site sends;
    Swell issues it for browsers ("safe to use in any context"). Variants
    expand 15 to a product unless asked for more."""
    cfg = brand["swell"]
    auth = "Basic " + base64.b64encode(f"{cfg['key']}:".encode()).decode()
    products = []
    for page in range(1, MAX_PRODUCTS // 100 + 1):
        url = f"https://{cfg['store']}.swell.store/api/products?limit=100&page={page}&expand=variants:100"
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json", "Authorization": auth})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.loads(r.read().decode("utf-8"))
        except (OSError, json.JSONDecodeError) as e:
            print(f"  ! {url}: {e}", file=sys.stderr)
            code = getattr(e, "code", None)
            FETCH_TROUBLE[brand["domain"]] = code in (None, 429) or (code is not None and code >= 500)
            break
        batch = body.get("results") or []
        products.extend(shape_swell(p) for p in batch)
        time.sleep(DELAY)
        if page >= (body.get("page_count") or 1) or not batch:
            break
    return products


WIX_PAGE = re.compile(r"<loc>\s*(https://[^<]+/product-page/[^<\s]+)\s*</loc>")
WIX_LD = re.compile(r'<script type="application/ld\+json"[^>]*>(.*?)</script>', re.S)


def shape_wix(url, html_text):
    """One Wix Stores product page in the shape Shopify's products.json uses,
    read from the page's own schema.org Product data (name, photos, price,
    stock) — the data Wix publishes for search engines. That data has one
    offer per product, not its sizes or colours (Wix loads those with
    JavaScript), so a Wix product is one variant here and the shopper picks
    the size on the brand's page, where Buy at <brand> sends them. None for a
    page with no Product data or no price."""
    product = None
    for m in WIX_LD.finditer(html_text):
        try:
            d = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        for item in d if isinstance(d, list) else [d]:
            if isinstance(item, dict) and item.get("@type") == "Product":
                product = item
    if not product:
        return None
    offer = product.get("offers") or {}
    offer = offer[0] if isinstance(offer, list) and offer else offer
    price = offer.get("price") if isinstance(offer, dict) else None
    if price in (None, ""):
        return None
    slug = url.rstrip("/").rsplit("/product-page/", 1)[1]
    images = product.get("image") or []
    images = images if isinstance(images, list) else [images]
    srcs = [i.get("contentUrl") or i.get("url") if isinstance(i, dict) else i for i in images]
    in_stock = str(offer.get("availability", "")).rstrip("/").endswith(("InStock", "LimitedAvailability", "PreOrder"))
    number = swell_number(f"wix:{slug}")
    return {
        "id": number,
        "title": html.unescape(product.get("name") or ""),
        "handle": slug,
        "product_type": "",
        "tags": [],
        "body_html": product.get("description") or "",
        "published_at": None,
        "images": [{"src": s} for s in srcs if isinstance(s, str) and s.startswith("https://")],
        "variants": [{"id": number, "title": "Default Title", "price": str(price), "compare_at_price": None,
                      "available": in_stock}],
        "options": [],
    }


def fetch_store_wix(brand):
    """A Wix Stores brand (owner, 2026-11-11: "lets do only one wix brand as
    a test"). Wix has no public product feed like Shopify's products.json:
    the store's product sitemap lists every product page, and each page
    carries schema.org Product data. One page at a time, DELAY apart; the
    store's robots.txt allows it. Checkout is on the brand's own page (the
    app's Buy at <brand> button), since a Wix cart needs a client ID the
    brand creates."""
    domain = brand["domain"]
    def get(url):
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/xml"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode("utf-8", "replace")
    try:
        sitemap = get(f"https://{domain}/store-products-sitemap.xml")
    except OSError as e:
        print(f"  ! {domain} store-products-sitemap.xml: {e}", file=sys.stderr)
        code = getattr(e, "code", None)
        FETCH_TROUBLE[domain] = code in (None, 429) or (code is not None and code >= 500)
        return []
    urls = list(dict.fromkeys(WIX_PAGE.findall(sitemap)))[:MAX_PRODUCTS]
    products = []
    for url in urls:
        try:
            shaped = shape_wix(url, get(url))
        except OSError as e:
            print(f"  ! {url}: {e}", file=sys.stderr)
            if getattr(e, "code", None) in (None, 429) or getattr(e, "code", 0) >= 500:
                FETCH_TROUBLE[domain] = True
                break
            continue
        if shaped:
            products.append(shaped)
        time.sleep(DELAY)
    return products


def fetch_store_woo(domain):
    """All products from a WooCommerce store's public Store API. Alcohol brands
    in particular run Woo rather than Shopify — age gates and state shipping
    rules push them off the standard platform — so this is the second door in."""
    products = []
    for page in range(1, MAX_PRODUCTS // WOO_PAGE_SIZE + 1):
        url = f"https://{domain}/wp-json/wc/store/products?per_page={WOO_PAGE_SIZE}&page={page}"
        try:
            batch = fetch_json(url)
        # ConnectionResetError and friends are OSErrors that never reach
        # urllib's URLError wrapper, so one store dropping the connection
        # used to kill a forty-minute build on its last page.
        except (OSError, json.JSONDecodeError) as e:
            print(f"  ! {url}: {e}", file=sys.stderr)
            break
        if not isinstance(batch, list):
            break
        products.extend(batch)
        time.sleep(DELAY)
        if len(batch) < WOO_PAGE_SIZE:
            break
    return products


def link_works(url):
    """Does this product page actually open on a phone? A Woo store can point
    at anything — Ten To One's feed links one bottle at a domain whose
    certificate doesn't cover it, which iOS blocks as unsafe. Shopify handles
    are generated from the same store, so only the hand-rolled ones are checked."""
    req = urllib.request.Request(url, headers={"User-Agent": UA}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status == 200
    except Exception as e:
        print(f"  ! dropping {url}: {e}", file=sys.stderr)
        return False
    finally:
        time.sleep(0.3)


def normalize_woo(p, brand):
    """One WooCommerce product in the same shape as a Shopify one. Prices come
    in minor units ("19900" = $199.00) and there are no variants to speak of:
    the Store API lists variation ids but not their prices, so a variable
    product is listed at its own price and opens on the brand's site."""
    title = html.unescape((p.get("name") or "").strip())
    if not title or SKIP.search(title):
        return None
    prices = p.get("prices") or {}
    unit = 10 ** int(prices.get("currency_minor_unit", 2))

    def money_minor(v):
        try:
            f = int(v) / unit
            return round(f, 2) if f > 0 else None
        except (TypeError, ValueError):
            return None

    price = money_minor(prices.get("price"))
    if price is None:
        return None
    regular = money_minor(prices.get("regular_price"))
    compare = regular if regular and regular > price else None
    images = [i["src"] for i in p.get("images", []) if i.get("src")][:MAX_IMAGES]
    if not images:
        return None
    available = bool(p.get("is_in_stock", True))
    categories = [c.get("name", "") for c in p.get("categories", [])]
    ptype = categories[0] if categories else None
    fields = {"title": title, "product_type": ptype or "", "tags": categories}
    # Placements an import reviewed, keyed by the product's slug (Woo's handle).
    slug = p.get("slug") or ""
    category = placed(brand.get("product_categories", {}).get(slug), fields, brand, slug)
    return {
        "id": f"{brand['id']}-{p['id']}",
        "brand": brand["id"],
        "title": title,
        "category": category,
        "subs": with_added_aisles(fields, category,
                                  brand.get("product_subcategories", {}).get(slug) or subcategories_of(fields, category)),
        "product_type": ptype,
        "price": price,
        "compare_at": compare,
        "images": images,
        "url": p.get("permalink") or f"https://{brand['domain']}/",
        "available": available,
        # One line, priced as listed; the Store API can't price variations.
        "variants": [{"id": int(p["id"]), "title": "Default Title", "price": price,
                      "compare_at": compare, "available": available}],
        "tags": [c for c in categories if len(c) < 40][:15],
        "description": clean_text(p.get("description") or p.get("short_description")),
        "published_at": None,
    }


def fetch_currency(domain):
    try:
        return (fetch_json(f"https://{domain}/meta.json").get("currency") or "").upper()
    except Exception:
        return ""
    finally:
        time.sleep(DELAY)


def clean_text(raw, limit=1200):
    if not raw:
        return None
    text = re.sub(r"<(br|/p|/li|/h\d)[^>]*>", "\n", raw, flags=re.I)
    text = re.sub(r"<li[^>]*>", "• ", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    text = re.sub(r"[ \t ]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text).strip()
    if len(text) > limit:
        text = text[:limit].rsplit(" ", 1)[0] + "…"
    return text or None


def fetch_share_image(domain):
    """The brand's og:image — the picture shown when its link is shared — for
    brands whose products can't be imported, so the app still has art for them.
    Resolves relative, protocol-relative and http:// URLs, and keeps the result
    only if it really serves an image. Two requests per brand."""
    try:
        req = urllib.request.Request(f"https://{domain}/", headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=30) as r:
            page = r.read(800_000).decode("utf-8", "replace")
    except Exception as e:
        print(f"  ! og:image {domain}: {e}", file=sys.stderr)
        return None
    finally:
        time.sleep(DELAY)
    m = (re.search(r'<meta[^>]+property=["\']og:image(?::secure_url)?["\'][^>]*content=["\']([^"\']+)', page, re.I)
         or re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]*property=["\']og:image', page, re.I))
    if not m:
        return None
    url = urllib.parse.urljoin(f"https://{domain}/", html.unescape(m.group(1).strip()))
    if url.startswith("http://"):
        url = "https://" + url[len("http://"):]
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30) as r:
            ok = (r.headers.get("Content-Type") or "").startswith("image/")
    except Exception:
        ok = False
    finally:
        time.sleep(DELAY)
    return url if ok else None


def money(v):
    try:
        f = float(v)
        return round(f, 2) if f > 0 else None
    except (TypeError, ValueError):
        return None


JEV_FILE = ROOT / "catalog" / "jev_categories.json"
JEV = json.loads(JEV_FILE.read_text()) if JEV_FILE.exists() else {}
JEV_MIN_CONFIDENCE = 0.85
# Second opinion (owner, 2026-11-12: "lets use decider as second opinion").
# A Jev verdict at 0.60-0.85 also counts when Perplexity's Decider v1.2, asked
# the same question about the same text (jev_categories.ask_second), picks the
# same department with p >= 0.5. Pilot with a blind Claude Opus 5.5 answer key
# (catalog/research/2026-11-12-decider-second-opinion/silver_report.md): on
# these unsure moves today's department was right 9.5% of the time, Jev alone
# 82%, Jev when Decider agreed at >= 0.5: 97% (69 of 116 sampled).
JEV_SECOND_FLOOR = 0.60
JEV_SECOND_MIN_P = 0.5


def jev_confident(v):
    """A jev_categories.json verdict sure enough to act on: Jev alone at
    JEV_MIN_CONFIDENCE, or Jev at JEV_SECOND_FLOOR with Decider agreeing about
    the same input."""
    if not v:
        return False
    if v["confidence"] >= JEV_MIN_CONFIDENCE:
        return True
    s = v.get("second") or {}
    return bool(v["confidence"] >= JEV_SECOND_FLOOR and s.get("choice") == v["choice"]
                and s.get("p", 0) >= JEV_SECOND_MIN_P and s.get("seen") == v["seen"])

import department_rules  # noqa: E402

# Departments the photo check moved on its own (clear tier, owner-approved
# 2026-10-12), keyed by product id; each applies only while the product shows
# the same first photo. photo_categories.py writes it; see apply_photo_move.
PHOTO_MOVES_FILE = ROOT / "catalog" / "photo_moves.json"
PHOTO_MOVES = json.loads(PHOTO_MOVES_FILE.read_text()) if PHOTO_MOVES_FILE.exists() else {}


def apply_photo_move(row, brand):
    """Last word after the keyword, Jev, rule and brand-fit passes, except over
    a hand pin. A changed first photo voids the move until it is re-checked."""
    m = PHOTO_MOVES.get(row["id"])
    if (not m or m["to"] == row["category"] or m["photo"] != department_rules.photo_key(row)
            or department_rules.hand_pinned(row, brand, sys.modules[__name__])):
        return False
    row["category"] = m["to"]
    row["subs"] = m.get("subs") or subcategories_of(row, m["to"])
    return True


def jev_key(row):
    """What a merchant edit would change. jev_categories.py keys verdicts on this."""
    raw = json.dumps([row.get("title"), row.get("product_type"), sorted(row.get("tags") or [])],
                     ensure_ascii=False)
    return hashlib.sha1(raw.encode()).hexdigest()[:12]


def apply_jev(row, brand):
    """Jev (catalog/jev_categories.py) re-files the products the keyword scoring
    is least sure of. Only a confident verdict for unchanged input applies.

    product_categories is mostly the import scripts freezing this same keyword
    guess (23k entries), which Jev may correct; an entry that DIFFERS from the
    keyword guess was placed on purpose (review_placement.py, a session's
    hand review) and always wins."""
    v = JEV.get(row["id"])
    if (not jev_confident(v) or v["choice"] == row["category"]
            or v["seen"] != jev_key(row)):
        return
    if department_rules.hand_pinned(row, brand, sys.modules[__name__]):
        return
    row["category"] = v["choice"]
    # A frozen aisle list belongs to the department it was frozen under.
    row["subs"] = subcategories_of(row, v["choice"])


def normalize(p, brand):
    # product_handles records what an import reviewed; it is not a limit. It
    # used to be, which quietly capped 760 brands at whatever their import
    # happened to carry and shrank them as stores renamed handles — Manière de
    # Voir was down to 23 of 987 in-stock products. A brand that really is
    # scoped says so with scope: "handles" (a store that sells other labels
    # alongside its own).
    if brand.get("scope") == "handles" and p.get("handle") not in (brand.get("product_handles") or []):
        return None
    # A store that also resells other labels (Hair Majesty stocks MIZANI and
    # Design Essentials beside its own wigs, 2026-11-04) names them here and
    # keeps listing its own new products, which a handle list would freeze.
    if (p.get("vendor") or "").strip().casefold() in {v.casefold() for v in brand.get("exclude_vendors") or []}:
        return None
    title = html.unescape((p.get("title") or "").strip())
    ptype = (p.get("product_type") or "").strip()
    if not title or SKIP.search(title) or SKIP.search(ptype):
        return None
    images = [i["src"] for i in p.get("images", []) if i.get("src")][:MAX_IMAGES]
    if not images:
        return None
    # Each colour's own photo (Shopify's variant featured_image), so the
    # product page can turn to it when that colour is picked (owner,
    # 2026-10-17). One past the first six photos is kept too: Walter Calvin's
    # Deep Navy is photo 8 of 19. Every colour gets its photo, however many
    # colours there are: a cap of eight left Styl Charm's Boston bag with no
    # photo for pink, blue, black or grey-black (owner, 2026-10-31), and 971
    # products like it. Lifting it added ~9k URLs (~1 MB) to the full catalog
    # only; the compact one the app bundles keeps one photo a product.
    variant_image = {}
    for v in p.get("variants", []):
        src = (v.get("featured_image") or {}).get("src")
        if not src:
            continue
        if src not in images:
            images.append(src)
        if src in images:
            variant_image[v["id"]] = images.index(src)
    variants = []
    for v in p.get("variants", []):
        price = money(v.get("price"))
        if price is None:
            continue
        variants.append({
            "id": v["id"],
            "title": html.unescape(v.get("title") or "Default Title"),
            "price": price,
            "compare_at": money(v.get("compare_at_price")),
            "available": bool(v.get("available", True)),
            **({"image": variant_image[v["id"]]} if v["id"] in variant_image else {}),
            # A Swell variant's own id, for marracat.com/go/swell (shape_swell).
            **({"swell": v["swell"]} if v.get("swell") else {}),
        })
    if not variants:
        return None
    # Reviewed product placement takes precedence over ambiguous merchant types
    # such as "Brush" (which otherwise looks like makeup) or seed cultivar names.
    category = placed(brand.get("product_categories", {}).get(p["handle"]), p, brand, p["handle"])
    pick = min((v for v in variants if v["available"]), key=lambda v: v["price"], default=variants[0])
    compare = pick["compare_at"] if pick["compare_at"] and pick["compare_at"] > pick["price"] else None
    tags = p.get("tags") or []
    if isinstance(tags, str):
        tags = [t.strip() for t in tags.split(",") if t.strip()]
    return {
        "id": f"{brand['id']}-{p['id']}",
        "brand": brand["id"],
        "title": title,
        "category": category,
        "subs": with_added_aisles(p, category,
                                  brand.get("product_subcategories", {}).get(p["handle"], subcategories_of(p, category))),
        "product_type": ptype or None,
        "currency": brand.get("currency", "USD"),
        "price": pick["price"],
        "compare_at": compare,
        "images": images,
        # Big Cartel's product pages are /product/<permalink>, Wix's
        # /product-page/<slug>; Shopify's and Swell's (Yeezy's at least)
        # /products/<handle>.
        "url": f"https://{brand['domain']}/{ {'bigcartel': 'product', 'wix': 'product-page'}.get(brand.get('platform'), 'products')}/{p['handle']}",
        **({"swell_product": p["swell_product"]} if p.get("swell_product") else {}),
        "available": any(v["available"] for v in variants),
        "variants": variants,
        **({"option_names": names} if (names := option_names(p)) else {}),
        "tags": [t for t in tags if len(t) < 40][:15],
        "description": clean_text(p.get("body_html")),
        "published_at": p.get("published_at") or p.get("created_at"),
    }


def storefront_tls():
    """TLS for a store's own HTML pages. Shopify's storefront answers 429 to
    every /collections/all from the refresh droplet's Python (OpenSSL 3.5,
    whose default key share adds the post-quantum X25519MLKEM768), while
    curl, Ubuntu's Python (OpenSSL 3.0) and the Mac get 200: best-seller
    ranks fell from 1,323 brands to 82 on the 2026-10-17 03:00 UTC run.
    Offering X25519 alone gets the page; products.json was never affected.
    macOS's /usr/bin/python3 (LibreSSL, which ship.sh runs with /usr/bin
    first on PATH) can't name the curve; its default offers no ML-KEM
    share anyway, so it keeps the default (2026-10-19)."""
    ctx = ssl.create_default_context()
    try:
        ctx.set_ecdh_curve("X25519")
    except ssl.SSLError:
        pass
    return ctx


STOREFRONT_TLS = storefront_tls()


def fetch_bestsellers(domain):
    """Product handles in the store's own best-selling order. products.json
    ignores sort_by, but the storefront collection page honours it, so read the
    handles off page one of /collections/all in the order they appear. Theme
    menus can slip a few extra handles in; only ones in our catalog count."""
    url = f"https://{domain}/collections/all?sort_by=best-selling"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30,
                                    context=STOREFRONT_TLS) as r:
            page = r.read(2_000_000).decode("utf-8", "replace")
    except Exception as e:
        print(f"  ! best-sellers {domain}: {e}", file=sys.stderr)
        return []
    finally:
        time.sleep(DELAY)
    handles = []
    for h in re.findall(r"/products/([a-z0-9][a-z0-9-]*)", page):
        if h not in handles:
            handles.append(h)
    return handles


def spread_lines(rows, cap):
    """The best `cap` products, spread across the brand's lines.

    Taking the first `cap` after sorting hands the whole allowance to whatever
    the brand dropped most recently: Fear of God's feed is 250 products across
    Essentials, the main line, footwear and bags, and the newest-first cut gave
    us 47 Essentials and almost nothing else.

    Products are grouped by product type and the first word of their title —
    where a brand names its line ("Essentials …", "Embossed …") — and each
    group gets a share of the cap in proportion to its size, with at least one
    of everything. Proportional rather than equal shares: a flat round-robin
    left the same brand with ten Essentials out of two hundred, which is just
    the opposite mistake. Order within a line is untouched, so in-stock best
    sellers still come first.
    """
    if len(rows) <= cap:
        return rows
    lines = {}
    for r in rows:
        first = (r.get("title") or "").split()
        key = ((r.get("product_type") or "").strip().lower(), first[0].lower() if first else "")
        lines.setdefault(key, []).append(r)
    groups = sorted(lines.values(), key=len, reverse=True)
    # One each first, then the rest of the cap by share of what's left.
    quota = {id(g): 1 for g in groups[:cap]}
    remaining = cap - len(quota)
    pool = sum(max(0, len(g) - 1) for g in groups if id(g) in quota)
    if pool:
        for g in groups:
            if id(g) not in quota or remaining <= 0:
                continue
            want = min(len(g) - 1, round(remaining * (len(g) - 1) / pool))
            quota[id(g)] += max(0, want)
    picked = [r for g in groups if id(g) in quota for r in g[:quota[id(g)]]]
    if len(picked) < cap:  # rounding can leave a few slots; fill them in order
        taken = {id(r) for r in picked}
        picked += [r for r in rows if id(r) not in taken][:cap - len(picked)]
    return picked[:cap]


def main():
    global DEPT_EVIDENCE, BRAND_FIT, brand_fit
    import brand_fit  # imports this module; loaded here to avoid a cycle at import time
    DEPT_EVIDENCE = department_rules.Evidence(sys.modules[__name__])
    BRAND_FIT = brand_fit.load()
    cached = "--cached" in sys.argv
    brands = json.loads(BRANDS.read_text())
    # --only a,b,c rebuilds those brands and splices them into the catalog that
    # is already there, so changing one brand's depth doesn't mean refetching a
    # thousand stores and reshuffling every other brand's selection.
    only = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--only=")), "")
    only = {b.strip() for b in only.split(",") if b.strip()}
    if only:
        missing = only - {b["id"] for b in brands}
        if missing:
            sys.exit(f"--only names brands that are not registered: {', '.join(sorted(missing))}")
        brands = [b for b in brands if b["id"] in only]
    CACHE.mkdir(exist_ok=True)
    stores, currencies = {}, {}

    def load_or_fetch(b):
        cache_file = CACHE / f"{b['domain']}.json"
        blob = json.loads(cache_file.read_text()) if cached and cache_file.exists() else None
        if not blob or not blob["products"]:  # an empty cache is a failed fetch, not an empty store
            print(f"fetching {b['domain']} …", flush=True)
            woo = b.get("platform") == "woocommerce"
            bc = b.get("platform") == "bigcartel"
            sw = b.get("platform") == "swell"
            wx = b.get("platform") == "wix"
            blob = {"products": fetch_store_woo(b["domain"]) if woo else fetch_store_bigcartel(b) if bc
                    else fetch_store_swell(b) if sw else fetch_store_wix(b) if wx else fetch_store(b["domain"]),
                    "currency": b.get("currency", "USD") if sw or wx else "USD" if woo or bc else fetch_currency(b["domain"]),
                    "platform": b.get("platform", "shopify")}
            cache_file.write_text(json.dumps(blob))
        return b["domain"], blob

    # Every brand is its own website, so FETCH_WORKERS stores are fetched at
    # once; pages of one store still go one at a time, DELAY apart. One at a
    # time, a full fetch of ~1,150 stores took over three hours (2026-10-05),
    # too slow for the 12-hourly refresh (scripts/refresh_catalog.sh).
    unique = list({b["domain"]: b for b in brands if b.get("shopify") and not b.get("hold")}.values())
    with ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
        fetched = dict(pool.map(load_or_fetch, unique))
    for b in unique:
        stores[b["domain"]] = fetched[b["domain"]]["products"]
        currencies[b["domain"]] = fetched[b["domain"]]["currency"]

    # Best-seller order per store drives "Trending" in search suggestions.
    best_file = CACHE / "bestsellers.json"
    best = json.loads(best_file.read_text()) if best_file.exists() else {}
    # No best-seller page to read on WooCommerce, Big Cartel or Swell.
    woo_domains = {b["domain"] for b in brands if b.get("platform") in ("woocommerce", "bigcartel", "swell", "wix")}
    for domain in stores:
        if domain in woo_domains:
            best.setdefault(domain, [])
    need = [d for d in stores if d not in woo_domains and (not cached or not best.get(d))]

    def bestsellers(domain):
        print(f"best-sellers {domain} …", flush=True)
        return domain, fetch_bestsellers(domain)

    with ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
        best.update(dict(pool.map(bestsellers, need)))
    best_file.write_text(json.dumps(best, indent=1))

    products, report = [], []
    for b in brands:
        if not b.get("shopify"):
            report.append(f"| {b['name']} | {b['domain']} | not a public Shopify feed | 0 | |")
            continue
        if b.get("hold"):
            # Registered but not live yet: a foreign-currency brand waits for
            # the owner's test checkout (2026-10-14). Deleting `hold` lists it.
            report.append(f"| {b['name']} | {b['domain']} | held: {b['hold']} | 0 | |")
            continue
        currency = currencies.get(b["domain"], "USD")
        # Every currency catalog/fx.py has a dollar rate for (owner, 2026-10-08:
        # the Nigerian, Kenyan, South African, Ghanaian and Swedish brands).
        if currency != "USD" and (currency not in fx.FALLBACK_PER_USD or b.get("currency") != currency):
            # Foreign currencies require an explicit registry review. Failed
            # discovery must never silently turn a store's prices into dollars.
            report.append(f"| {b['name']} | {b['domain']} | skipped: prices in {currency} | 0 | |")
            b["shopify"] = False
            continue
        b["currency"] = currency
        shape = normalize_woo if b.get("platform") == "woocommerce" else normalize
        rows = [n for n in (shape(p, b) for p in stores.get(b["domain"], [])) if n]
        for r in rows:
            apply_jev(r, b)
        # The merchant's own product type, gift sets filed with what's in
        # them (department_rules.py), then Jev's cached brand-fit verdicts
        # (brand_fit.py, asked by the refresh), so a --only rebuild keeps them.
        department_rules.refine(rows, b, sys.modules[__name__], DEPT_EVIDENCE)
        brand_fit.apply(rows, {b["id"]: b}, BRAND_FIT)
        for r in rows:
            apply_photo_move(r, b)
        department_rules.file_adult(rows, b)
        if b.get("platform") == "woocommerce":
            rows = [r for r in rows if link_works(r["url"])]
            # A Woo brand checked out from the app lists only the products whose
            # checkout hand-off was verified (simple products; no subscriptions,
            # gift cards or options the checkout link can't choose).
            if b.get("product_ids"):
                allowed = set(b["product_ids"])
                rows = [r for r in rows if r["variants"][0]["id"] in allowed]
        if b.get("only_categories"):
            rows = [r for r in rows if r["category"] in b["only_categories"]]
        if b.get("exclude_categories"):
            rows = [r for r in rows if r["category"] not in b["exclude_categories"]]
        # The brand's own best-seller order, counted over the products we list
        # (top 20 only — below that the storefront order is noise).
        # Shopify URLs carry the handle the best-seller page lists; Woo's don't.
        if b.get("platform") not in ("woocommerce", "bigcartel", "swell", "wix"):
            listed = {r["url"].rsplit("/products/", 1)[1]: r for r in rows if "/products/" in r["url"]}
            ranked = [h for h in best.get(b["domain"], []) if h in listed]
            for n, h in enumerate(ranked[:20]):
                listed[h]["best_rank"] = n
        # In stock first, then top sellers (so the cap never drops them), then newest.
        rows.sort(key=lambda r: (not r["available"], r.get("best_rank", 20),
                                 -(time.mktime(time.strptime(r["published_at"][:19], "%Y-%m-%dT%H:%M:%S"))
                                   if r["published_at"] else 0)))
        rows = spread_lines(rows, b.get("product_cap") or PER_BRAND_CAP)
        products.extend(rows)
        counts = {}
        for r in rows:
            counts[r["category"]] = counts.get(r["category"], 0) + 1
        mix = ", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1]))
        report.append(f"| {b['name']} | {b['domain']} | ok | {len(rows)} | {mix} |")

    # Keep curated product photos from the registry. Only fall back to the
    # website's share image when no photo or imported products are available.
    share_file = CACHE / "share-images.json"
    share = json.loads(share_file.read_text()) if share_file.exists() else {}
    have_products = {p["brand"] for p in products}
    for b in brands:
        if b.get("image") or b["id"] in have_products:
            continue
        if not cached or b["domain"] not in share:
            print(f"og:image {b['domain']} …")
            share[b["domain"]] = fetch_share_image(b["domain"])
        if share.get(b["domain"]):
            b["image"] = share[b["domain"]]
    share_file.write_text(json.dumps(share, indent=1))

    # The Marracat Clean badge, from ingredient lists already stored in
    # catalog/ingredients.json. Fetching new lists is clean_badge.py --scrape,
    # which ship.sh runs; a rebuild must not drop the flags in the meantime.
    from clean_badge import apply as apply_clean_badge, load as load_lists, STORE as LISTS
    stats, _, _, _, _ = apply_clean_badge(products, load_lists(LISTS, {}))
    badged = sum(f["passed"] for f in stats.values())
    listed = sum(f["listed"] for f in stats.values())
    print(f"clean badge: {badged} products badged from {listed} stored ingredient lists")

    # The Marracat True Metal jewelry badge (catalog/metal_standard.md), from
    # what each listing says about its metal. No fetching, so a rebuild sets it
    # every time.
    from metal_badge import apply as apply_metal_badge
    mstats, _, _, _, _ = apply_metal_badge(products)
    print(f"true metal badge: {mstats['true'] + mstats['ethical']} jewelry products badged "
          f"({mstats['ethical']} ethically sourced) of {mstats['eligible']}")

    # Marracat Clear Scent (catalog/scent_standard.md) and Marracat Safer Clean
    # (catalog/safer_clean_standard.md), from the ingredient lists already stored
    # beside Clean's. Fetching new lists is ship.sh's job (--scrape, capped).
    from scent_badge import apply as apply_scent_badge
    from safer_clean_badge import apply as apply_safer_badge
    lists = load_lists(LISTS, {})
    sstats, _, _, _ = apply_scent_badge(products, lists)
    cstats, _, _, _ = apply_safer_badge(products, lists)
    print(f"clear scent badge: {sstats['passed']} of {sstats['eligible']} fragrances; "
          f"safer clean badge: {cstats['passed']} of {cstats['eligible']} cleaning products")

    # Marracat Clean Food (catalog/food_standard.md) and Marracat Baby Safe
    # (catalog/baby_standard.md): from each product's own description plus the
    # page lists already stored; ship.sh fetches new pages (--scrape, capped).
    from food_badge import apply as apply_food_badge
    from baby_badge import apply as apply_baby_badge
    fstats, _, _, _ = apply_food_badge(products, lists)
    bstats, _, _, _ = apply_baby_badge(products, lists)
    print(f"clean food badge: {fstats['passed']} of {fstats['eligible']} foods; "
          f"baby safe badge: {bstats['passed']} of {bstats['eligible']} baby products")

    # Marracat Natural Fiber (catalog/fiber_standard.md) and Marracat Safe
    # Fabric (catalog/fabric_standard.md): from each garment's own description.
    from fiber_badge import apply as apply_fiber_badge
    from fabric_badge import apply as apply_fabric_badge
    nstats, _, _, _ = apply_fiber_badge(products)
    xstats, _, _, _ = apply_fabric_badge(products)
    print(f"natural fiber badge: {nstats['passed']} of {nstats['eligible']} garments; "
          f"safe fabric badge: {xstats['passed']} of {xstats['eligible']} garments")

    # Marracat Lab Verified (catalog/lab_standard.md), Pet Safe
    # (catalog/pet_standard.md), True Material (catalog/material_standard.md)
    # and Natural Home (catalog/home_standard.md): from each listing's own text;
    # pet grooming lists also come from the stored ingredient lists.
    from lab_badge import apply as apply_lab_badge
    from pet_badge import apply as apply_pet_badge
    from material_badge import apply as apply_material_badge
    from home_badge import apply as apply_home_badge
    lstats, _, _, _ = apply_lab_badge(products)
    pstats, _, _, _ = apply_pet_badge(products, lists)
    mstats2, _, _, _ = apply_material_badge(products)
    hstats, _, _, _ = apply_home_badge(products)
    print(f"lab verified badge: {lstats['passed']} of {lstats['eligible']} wellness products; "
          f"pet safe badge: {pstats['passed']} of {pstats['eligible']} pet products; "
          f"true material badge: {mstats2['passed']} of {mstats2['eligible']} bags; "
          f"natural home badge: {hstats['passed']} of {hstats['eligible']} home products")

    # A store that lists one product several times (same title, same photo) would show
    # it several times in a grid; keep one copy. See dedupe_products.py.
    from dedupe_products import dedupe
    products, folded = dedupe(products, {b["id"]: b.get("category") for b in brands})
    print(f"dedupe: {len(folded)} repeat listings folded into their products")
    catalog = {
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "categories": CATEGORIES,
        "subcategories": [s for s in flat_subcategories()
                          if s["id"] in {f"{p['category']}:{sub}" for p in products for sub in p["subs"]}],
        # A brand with nothing to sell is not a shelf: six stores are locked or
        # unpaid (401/402) and would otherwise show up empty. They stay in
        # brands.json, so they come back the day their store does.
        "brands": [{**{k: b[k] for k in ("id", "name", "domain", "category", "tagline", "shopify", "image", "currency", "ucp", "checkout", "bigcartel", "swell", "ships_from", "country", "instagram") if k in b},
                    "platform": b.get("platform", "shopify")}
                   for b in brands if b["id"] in {p["brand"] for p in products}],
        "products": products,
    }
    # A store that was merely unreachable keeps the products it had: a 429 for
    # a minute used to empty a brand out of the catalog entirely (Bohten, which
    # answered fine again ten minutes later). A store that is locked or unpaid
    # is dropped, because nothing there can be bought.
    if OUT.exists():
        listed = {p["brand"] for p in catalog["products"]}
        missing = [b for b in brands if b["id"] not in listed]
        # Only the unreachable stores' products are read back, one at a time
        # (catalog_io.products_of_brands): the whole previous catalog beside
        # this one ran the refresh server out of memory on 2026-11-12.
        had, sold_before = products_of_brands(OUT, {b["id"] for b in missing if FETCH_TROUBLE.get(b["domain"])})
        rescued = 0
        for b in missing:
            if b["id"] not in sold_before:
                continue
            if FETCH_TROUBLE.get(b["domain"]):
                catalog["products"].extend(had[b["id"]])
                rescued += len(had[b["id"]])
                # Its brand entry too: the brand list was made before the
                # rescue, and products whose brand isn't listed break the app
                # and the site (79 brands on 2026-10-05).
                catalog["brands"].append({**{k: b[k] for k in ("id", "name", "domain", "category", "tagline", "shopify", "image", "currency", "ucp", "checkout", "bigcartel", "swell", "ships_from", "country", "instagram") if k in b},
                                          "platform": b.get("platform", "shopify")})
                print(f"  kept {len(had[b['id']])} products for {b['id']}: {b['domain']} did not answer this run",
                      file=sys.stderr)
            else:
                print(f"  dropped {b['id']}: {b['domain']} has nothing for sale", file=sys.stderr)
        if rescued:
            print(f"carried {rescued} products through stores that were briefly unreachable")
            catalog["products"] = in_registry_order(catalog["products"], brands, lambda p: p["brand"])
            catalog["brands"] = in_registry_order(catalog["brands"], brands, lambda b: b["id"])
            # Those products may use aisles nothing else in this build touches.
            used = {f"{p['category']}:{sub}" for p in catalog["products"] for sub in p["subs"]}
            catalog["subcategories"] = [s for s in flat_subcategories() if s["id"] in used]

    if only:
        # Keep every other brand exactly as it is; swap in the rebuilt ones.
        existing = json.loads(OUT.read_text())
        rebuilt = {b["id"] for b in catalog["brands"]}
        existing["products"] = [p for p in existing["products"] if p["brand"] not in rebuilt] + catalog["products"]
        by_id = {b["id"]: b for b in catalog["brands"]}
        existing["brands"] = [by_id.get(b["id"], b) for b in existing["brands"]]
        # A brand the last build left out — an empty store, or one whose
        # currency had not been reviewed — comes back with its products rather
        # than leaving them in the catalog with no brand to belong to.
        known = {b["id"] for b in existing["brands"]}
        existing["brands"] += [b for b in catalog["brands"] if b["id"] not in known]
        existing["brands"].sort(key=lambda b: b["name"].lower())
        # Where a brand ships from is the registry's, not the store's, so the
        # brands this run didn't rebuild still follow brands.json for it.
        # The country it is based in (brand_country.py) is the registry's as well.
        registry = {b["id"]: b for b in json.loads(BRANDS.read_text())}
        for b in existing["brands"]:
            for field in ("ships_from", "country"):
                if registry.get(b["id"], {}).get(field):
                    b[field] = registry[b["id"]][field]
                else:
                    b.pop(field, None)
        existing["generated_at"] = catalog["generated_at"]
        used = {f"{p['category']}:{sub}" for p in existing["products"] for sub in p["subs"]}
        existing["subcategories"] = [s for s in flat_subcategories() if s["id"] in used]
        catalog = existing
    # Dollars per unit on each non-dollar brand, for the app's dollar sorting,
    # filters and "≈ $" estimates (catalog/fx.py).
    fx.apply(catalog["brands"], fx.usd_rates())
    # The app and the site key everything on the id; whatever path brought a
    # repeat in (paging, a rescued brand), one copy goes out.
    catalog["products"], repeats = unique_by_id(catalog["products"])
    if repeats:
        print(f"dropped {repeats} products repeating an id")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    write_catalog(OUT, catalog)
    # What the app actually bundles. The full file beside it is the source the
    # scripts and the website read, and project.yml keeps it out of the target.
    from publish_snapshots import compact_catalog
    compact = compact_catalog(catalog)
    write_catalog(COMPACT_OUT, compact)
    print(f"wrote {COMPACT_OUT.relative_to(ROOT)}: "
          f"{COMPACT_OUT.stat().st_size / 1e6:.0f} MB for the app bundle")
    # A partial rebuild has nothing to say about the brands it didn't touch, so
    # it leaves the report alone rather than replacing it with eight rows.
    if not only:
        REPORT.write_text("# Catalog build report\n\n"
                          f"Generated {catalog['generated_at']} — {len(products)} products.\n\n"
                          "| Brand | Store | Status | Products | Category mix |\n|---|---|---|---|---|\n"
                          + "\n".join(report) + "\n")
    linked = sum(1 for p in products if p["subs"])
    print(f"wrote {OUT.relative_to(ROOT)}: {len(products)} products, "
          f"{OUT.stat().st_size / 1e6:.1f} MB, {linked} linked to "
          f"{len(catalog['subcategories'])} subcategories ({linked * 100 // max(len(products), 1)}%)")


if __name__ == "__main__":
    main()
