#!/usr/bin/env python3
"""Award the Marracat Clean badge from a product's published ingredient list.

The rules are in catalog/clean_standard.md. In short: the badge goes to hair
products, face washes and body washes whose brand publishes a full INCI list,
where nothing on that list is banned under EU Regulation (EC) 1223/2009 or the
extra rules the standard adds, fragrance is disclosed to the EU allergen level,
and the product is not in an excluded category.

Nothing in a badged product is banned in a major cosmetics market. The EU list
is the longest anywhere, over 1,700 substances, and it bans CMR 1A/1B
substances automatically, so it is the base; the US bans about 30. Where
another market bans something the EU still permits, or a US retailer standard
(Clean at Sephora, Target Clean) is stricter, the stricter rule wins.

Ingredient lists live on the brand's product page, not in the products.json
feed the catalog is built from, so this script fetches each eligible product
page once and keeps what it finds:

  catalog/ingredients.json          product URL -> INCI text (committed; the
                                    badge must be reproducible from the repo)
  catalog/.cache/ingredients-miss.json
                                    product URL -> fetch date, for pages with
                                    no list (retried after MISS_TTL_DAYS)

Usage:
    python3 catalog/clean_badge.py            # re-evaluate from stored lists
    python3 catalog/clean_badge.py --scrape   # also fetch lists not yet stored
    python3 catalog/clean_badge.py --scrape --max-new 200
    python3 catalog/clean_badge.py --explain <product-id>

Writes `clean: true` onto passing products in Marracat/Resources/catalog.json
(absent otherwise, to keep the 48 MB catalog from growing) and a report at
catalog/clean_report.md. Stdlib only.
"""
import argparse
import concurrent.futures
import datetime as dt
import html
import json
import pathlib
import re
import sys
import threading
import time
import urllib.parse
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from candle_badge import is_candle, evaluate_candle  # noqa: E402
import relaxed_lists  # noqa: E402  Jev-confirmed second reading (2026-10-09)
from catalog_io import write_catalog  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Marracat" / "Resources" / "catalog.json"
STORE = ROOT / "catalog" / "ingredients.json"
MISSES = ROOT / "catalog" / ".cache" / "ingredients-miss.json"
REPORT = ROOT / "catalog" / "clean_report.md"

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
DELAY = 1.0            # seconds between requests to one store
STORE_WORKERS = 8      # stores fetched in parallel; each store stays sequential
MISS_TTL_DAYS = 30
MIN_TOKENS = 8         # shortest run of ingredient-looking names that counts as a list

# --- which products the badge can apply to ------------------------------------------

# Hair products that aren't formulations: nothing to read, so never scraped.
# Sets and packs hold several formulas that one page list can't vouch for.
GEAR = re.compile(
    r"\b(wig|wigs|extension|extensions|bundle|bundles|closure|frontal|lace|braids?|braided|"
    r"locs?|crochet|bonnet|brush|comb|tools?|dryer|scarf|durag|du-rag|clip-?in|ponytail|weave|"
    r"hair ?piece|bun|scrunchie|headband|towels?|washcloths?|wipes?|pillowcase|caps?|steamer|"
    r"diffuser|flat iron|combs?|brush(es)?|"
    r"curling|blow|kit|e-?book|course|gift card|shirt|hoodie|tee|lashes|appointment|deposit|"
    r"consultation|service|duo|trio|quad|packs?|kits?|regimen|collection|system|gift|"
    r"\d[- ]?(piece|pc)|set of|sets?\s*\(|set$|"
    # makeup and skincare tools: nothing to read
    r"sponges?|blenders?|mirrors?|sharpeners?|tweezers?|nail files?|press[- ]?on|false lashes|mink|"
    r"cases?|pouch(es)?|organi[sz]ers?|gua sha|rollers?|jade|washcloths?|loofahs?|pumice|razors?|"
    r"dermaplan\w*|applicators?|palette case|bags?|sticker|shirt|hoodie|tee|e-?gift)\b", re.I)

# A face wash: a rinse-off facial cleanser.
FACE_WASH = re.compile(
    r"\bface ?wash\b|\bfacial (cleanser|wash)\b|\b(face|facial)\b[^,]{0,24}\b(cleanser|cleansing|wash)\b|"
    r"\bcleansing (gel|foam|milk|balm|oil|cream|bar|wash)\b|\bfoaming cleanser\b|\bgel cleanser\b|"
    r"\bcream cleanser\b|\boil cleanser\b|\bcleanser\b", re.I)
# A body wash or soap: also rinse-off.
BODY_WASH = re.compile(
    r"\bbody ?wash\b|\bshower (gel|cream|wash)\b|\bbody soap\b|\bbar soap\b|\bsoap bar\b|"
    r"\bhand (soap|wash)\b|\bcastile\b|\bbubble bath\b|\bcleansing bar\b|\bblack soap\b|"
    r"\bsavon\b|\bsoap\b", re.I)
# Leave-on skincare that the cleanser keywords can otherwise pull in.
NOT_A_WASH = re.compile(
    r"\bserum\b|\btoner\b|\bmoisturi[sz]er\b|\blotion\b|\bbutter\b|\bcream$|\bmask\b|\bmasque\b|"
    r"\bscrub\b|\bexfoliant\b|\bspf\b|\bsunscreen\b|\bdeodorant\b|\bmist\b|\boil$|\bbalm$|"
    r"\bcandle\b|\bdish\b|\blaundry\b|\bdetergent\b|\bcleaner\b|\bshampoo\b|\bconditioner\b|"
    r"\bcarpet\b|\bupholstery\b|\bsurface\b|\bfloor\b|\btoilet\b|\bglass\b|\bpet\b|\bdog\b", re.I)

# Never badged, whatever the formula. Relaxers and straighteners carry an
# established cancer or formaldehyde-exposure association (FDA's proposed rule
# on formaldehyde straighteners); permanent colour runs on PPD and resorcinol;
# skin bleaching is the product class that mercury and hydroquinone
# adulteration keeps turning up in, and it is marketed hard to Black shoppers.
EXCLUDED_SUBS = {"relaxer", "color"}
EXCLUDED_TITLE = re.compile(
    r"\b(relaxer|relaxing|texturi[sz]er|keratin (treatment|smoothing)|brazilian (blowout|keratin)|"
    r"straightening (treatment|cream|system)|smoothing treatment|permanent (colou?r|dye)|"
    r"hair (colou?r|dye)|bleaching|skin lightening|lightening (cream|soap|lotion)|"
    r"whitening|skin bleach)\b", re.I)


# A beauty product no rule could place (a name-only title, "for Braids" read
# as hair gear) is checked when Jev was sure it's one product with its own
# formula (catalog/jev_eligibility.py, owner 2026-10-09: "make sure other
# products aren't missed").
_JEV_FAMILY = {"hair": "hair", "makeup": "makeup", "skincare": "skin"}


def family(product):
    fam = _family_by_rules(product)
    if fam is None and product.get("category") in _JEV_FAMILY:
        import eligibility as el
        if el.jev_says("beauty", product):
            return _JEV_FAMILY[product["category"]]
    return fam


def _family_by_rules(product):
    """'hair', 'face', 'body', 'skin', 'makeup', 'candle', or None when the
    badge can't apply."""
    title = product.get("title") or ""
    ptype = product.get("product_type") or ""
    subs = set(product.get("subs") or [])
    text = f"{title} {ptype}"
    # Candles have their own rules (candle_badge.py): they aren't cosmetics.
    if is_candle(product):
        return "candle"
    if GEAR.search(f"{text} {' '.join(subs)}") or subs & {"tools", "brushes", "skincare-sets", "makeup-sets"}:
        return None
    if product.get("category") == "hair":
        return "hair"
    if product.get("category") == "makeup":
        return "makeup"
    # A serum or lotion isn't a wash, but it is still leave-on skincare.
    if NOT_A_WASH.search(text):
        return "skin" if product.get("category") == "skincare" else None
    face_hit = bool(FACE_WASH.search(text))
    body_hit = bool(BODY_WASH.search(text)) or bool(subs & {"body-wash", "hand-soap"})
    names_face = bool(re.search(r"\b(face|facial)\b", text, re.I))
    names_body = bool(re.search(r"\b(body|hand|shower|bath)\b", text, re.I))
    # "Body Cleanser Bar" sits in the cleanser aisle but is a body wash, so the
    # part of the body the title names decides before the aisle does.
    # An intimate wash is a rinse-off body cleanser, whichever aisle it sits in.
    if "intimate" in subs and (face_hit or body_hit):
        return "body"
    if body_hit and names_body and not names_face:
        return "body"
    if face_hit and (names_face or "cleanser" in subs):
        return "face"
    if body_hit:
        return "body"
    # Serums, moisturisers, oils, butters, masks, sunscreens, lip care: the
    # rest of skincare, which stays on the skin.
    if product.get("category") == "skincare":
        return "skin"
    return None


# --- the ban list -----------------------------------------------------------------
# label, regex over one INCI token, where the rule comes from. "EU Annex II" is
# Regulation (EC) 1223/2009's prohibited list; anything CMR 1A/1B is on it
# automatically under Article 15.
BANNED = [
    ("formaldehyde or a releaser",
     r"formaldehyde|formalin|methylene glycol|dmdm hydantoin|quaternium-15|imidazolidinyl urea|"
     r"diazolidinyl urea|bronopol|2-bromo-2-nitropropane|sodium hydroxymethylglycinate|"
     r"polyoxymethylene|glyoxal|benzylhemiformal",
     "EU Annex II (formaldehyde); EU labels any releaser over 10 ppm (Reg. 2022/1181)"),
    ("parabens", r"\w*paraben\b",
     "EU Annex II bans 5 parabens; Annex V caps propyl/butyl at 0.14%, unverifiable from a list"),
    ("phthalates", r"phthalate",
     "EU Annex II (DEHP, DBP, BBP); Helm et al. 2018 found DEP in Black hair products"),
    ("nonylphenol ethoxylates", r"nonylphenol|nonoxynol",
     "EU Annex II; Helm et al. 2018"),
    ("cyclic silicones", r"cyclotetrasiloxane|cyclopentasiloxane|cyclohexasiloxane|cyclomethicone|"
     r"cyclotrisiloxane|\bd4\b|\bd5\b|\bd6\b",
     "D4 on EU Annex II since 2022; REACH caps D5/D6 at 0.1% from June 2026"),
    ("zinc pyrithione", r"pyrithione",
     "EU Annex II since March 2022, reprotoxic 1B (Reg. 2021/1902)"),
    ("lilial (butylphenyl methylpropional)", r"butylphenyl methylpropional|\blilial\b|\bbmhca\b",
     "EU Annex II since March 2022, reprotoxic 1B"),
    ("lyral (HICC)", r"hydroxyisohexyl 3-cyclohexene|\bhicc\b|\blyral\b",
     "EU Annex II since August 2021, sensitiser"),
    ("microplastics", r"\bpolyethylene\b(?! glycol)|\bpolypropylene\b(?! glycol)|"
     r"polymethyl methacrylate|\bpmma\b|"
     r"\bnylon-?\d+\b|\bptfe\b|polytetrafluoroethylene",
     "EU REACH Reg. 2023/2055; exfoliating microbeads banned outright since Oct 2023"),
    ("EDTA and its salts", r"\bedta\b|edetate|edetic acid|ethylenediaminetetraacetic",
     "excluded by the EU Ecolabel for cosmetics (poor biodegradability); Clean at Sephora since 2024"),
    ("SLS / SLES", r"(sodium|ammonium) (lauryl|laureth|myreth) sulfate|sodium lauryl ether sulfate",
     "stricter than the EU: Clean at Sephora and Target Clean; ethoxylates carry 1,4-dioxane"),
    ("ethanolamines", r"\w*th[ae]nolamine|^(tea|dea|mea)\b|\b(cocamide|lauramide|oleamide|linoleamide) (dea|mea)\b",
     "EU Annex II bans diethanolamine and caps nitrosamines; Clean at Sephora"),
    ("triclosan / triclocarban", r"triclosan|triclocarban",
     "FDA removed both from soap in 2016; EU caps triclosan at 0.3%, unverifiable from a list"),
    ("hydroquinone", r"hydroquinone", "EU Annex II for skin products; Clean at Sephora"),
    # (Carbon black, CI 77266, is a permitted colourant in the EU and US and is
    # not coal tar, so mascara and eyeliner aren't failed for it.)
    ("coal tar", r"coal tar", "EU Annex II; Clean at Sephora"),
    ("lead acetate", r"lead acetate|^lead$",
     "EU Annex II; FDA withdrew its hair-dye approval in 2018"),
    ("mercury", r"mercur|thimerosal|thiomersal", "EU Annex II; California TFCA (2025)"),
    ("PFAS", r"perfluoro|polyfluoro|fluorotelomer", "EU restricts; California TFCA (2025)"),
    ("BHA / BHT", r"butylated hydroxy|^bha$|^bht$", "Clean at Sephora; Target Clean"),
    ("isothiazolinone preservatives", r"isothiazolinone",
     "EU bans MIT in leave-on and caps rinse-off at 15 ppm, unverifiable from a list"),
    ("toluene", r"^toluene$|\btoluene\b(?!-)", "EU Annex II outside nail products"),
    ("resorcinol", r"^resorcinol$", "EU Annex III, hair dye only; Clean at Sephora"),
    ("p-phenylenediamine", r"phenylenediamine|toluene-2,5-diamine",
     "EU Annex III, permanent dye only; excluded category here"),
    ("synthetic musks", r"musk (ketone|xylene|ambrette)|galaxolide|tonalide|\bhhcb\b|\bahtn\b",
     "excluded by the EU Ecolabel; Target Clean"),
    ("lye / thioglycolate relaxer actives", r"guanidine (carbonate|hydroxide)|thioglycolate|thioglycolic",
     "relaxer chemistry; the category is never badged"),
    # Sunscreen filters. Palau banned "reef-toxic" sunscreens in 2020, the first
    # country to; the EU banned 4-MBC outright in 2025.
    ("4-MBC", r"4-methylbenzylidene camphor|\benzacamene\b|\b4-mbc\b",
     "EU Annex II from May 2025 (Reg. 2024/996), an endocrine disruptor; in Palau's 2020 sunscreen ban"),
    ("oxybenzone and benzophenones", r"oxybenzone|benzophenone",
     "Palau's 2020 sunscreen ban (oxybenzone); Clean at Sephora excludes benzophenones"),
    ("octinoxate", r"octinoxate|ethylhexyl methoxycinnamate|octyl methoxycinnamate",
     "Palau's 2020 sunscreen ban; Clean at Sephora"),
    ("octocrylene", r"\boctocrylene\b", "Palau's 2020 sunscreen ban; Clean at Sephora"),
    ("retinyl palmitate", r"retinyl palmitate",
     "excluded by Clean at Sephora and Target Clean; the EU caps vitamin A (Reg. 2024/996)"),
    # Banned somewhere the EU still permits them. Japan runs its preservatives
    # and colourants on approved lists, so anything left off is unusable there
    # however Europe rates it.
    ("chlorphenesin", r"chlorphenesin",
     "not permitted as a preservative in Japan; the EU allows it at 0.3%"),
    ("iodopropynyl butylcarbamate", r"iodopropynyl|\bipbc\b",
     "not permitted in Japan; the EU allows it at 0.01–0.02%"),
    ("rhodamine B", r"rhodamine|\bci 45170\b",
     "banned as a colourant in Japan"),
]

FRAGRANCE = re.compile(r"\b(fragrance|parfum|perfume|aroma|scent|natural scent)\b", re.I)
UNSCENTED = re.compile(r"(fragrance|parfum|scent)[\s:-]*free|free of (fragrance|parfum)|unscented|"
                       r"no (added )?(fragrance|scent)", re.I)
# The allergens EU Regulation 2023/1545 requires to be named individually on the
# label, in force for new products from 31 July 2026. Lilial and Lyral are not
# here: the EU banned both outright, so they are on the ban list above.
ALLERGENS = re.compile(
    r"\b(linalool|limonene|citral|geraniol|citronellol|citronellal|eugenol|isoeugenol|"
    r"benzyl benzoate|benzyl salicylate|benzyl cinnamate|coumarin|6-methylcoumarin|"
    r"hexyl cinnamal|cinnamal|cinnamyl alcohol|farnesol|hydroxycitronellal|amyl cinnamal|"
    r"amylcinnamyl alcohol|anise alcohol|anisyl alcohol|alpha-isomethyl ionone|"
    r"evernia (prunastri|furfuracea)|oak ?moss|tree ?moss|methyl 2-octynoate|"
    r"acetylcedrene|amyl salicylate|methyl salicylate|anethole|benzaldehyde|camphor|"
    r"caryophyllene|carvone|damascone|damascenone|dimethylbenzyl carbinyl acetate|"
    r"hexadecanolactone|hexenal|linalyl acetate|menthol|nerol|nerolidol|"
    r"pinene|piperonal|salicylaldehyde|santalol|sclareol|terpinene|terpineol|terpinolene|"
    r"vanillin|isoamyl|geranyl acetate|cinnamyl)\b", re.I)
# One allergen name can be a solvent or preservative doing another job (benzyl
# benzoate, menthol, camphor). A disclosure names the set, so two are required.
MIN_ALLERGENS = 2
# …and these carry another job often enough that they can't prove one on their
# own: menthol and camphor are actives, benzyl benzoate a solvent, vanillin and
# methyl salicylate flavour and counter-irritant. They still count as allergens,
# just not as evidence that the brand disclosed its fragrance.
AMBIGUOUS_ALLERGENS = re.compile(
    r"^(menthol|camphor|benzyl benzoate|vanillin|benzaldehyde|salicylaldehyde|"
    r"methyl salicylate|anethole)$", re.I)

# Allowed but noted: a hair-preference or tradition question, not a safety one.
NOTED = [
    ("petrolatum / mineral oil", r"petrolatum|mineral oil|paraffinum liquidum|petroleum jelly"),
    ("linear silicones", r"dimethicone|amodimethicone|dimethiconol|trimethicone|siloxane"),
]

# --- finding the INCI list on a page ----------------------------------------------

INCI_WORD = re.compile(
    r"\b(water|aqua|eau|glycerin|glycerol|oil|extract|butter|alcohol|acid|seed|leaf|root|fruit|"
    r"flower|juice|protein|amino|peg-?\d|ppg-?\d|\w+eth-?\d|polyquaternium|panthenol|tocopher|"
    r"parfum|fragrance|phenoxyethanol|glycol|sodium|potassium|cetyl|stearyl|cetearyl|behen|"
    r"hydroxy|capryl|capric|hydrolyzed|ceramide|keratin|biotin|niacinamide|allantoin|menthol|"
    r"camphor|lanolin|beeswax|cera |honey|mel\b|aloe|silk|wax|clay|powder|starch|sugar|vinegar|"
    r"charcoal|benzoate|sorbate|mica|titanium|zinc|iron oxides|magnesium|calcium|silica|kaolin|"
    r"bentonite|rhassoul|ci \d{5}|d&c|fd&c|fdc|dc (red|blue|violet|yellow|green|orange)|carbomer|"
    r"xanthan|gum|betaine|glucoside|sulfonate|sulfate|sulphate|chloride|citrate|lactate|"
    r"stearate|palmitate|oleate|laurate|myristate|acetate|cocoate|dimethicone|siloxane|"
    r"quaternium|hydantoin|urea|paraben|phthalate|triclosan|saponified|\w+ol\b|\w+ide\b|\w+ine\b|"
    r"\w+one\b|\w+ium\b|\w+ane\b|\w+yl\b|\w+ate\b|\w+ose\b|\w+ene\b|\w+ase\b|"
    r"[a-z]+ [a-z]+ \([a-z ]+\))", re.I)
# Once a run is under way, a short chemical-looking name keeps it going even
# when the vocabulary above doesn't know it ("Laureth-23", "Benzotriazolyl
# Dodecyl P-Cresol"). Marketing copy is longer and wordier than this.
INCI_SHAPE = re.compile(r"^[A-Za-z0-9()/&'#.,%+*\- ]{2,70}$")
LABEL = re.compile(r"ingredients?\s*[:\-–]?\s*", re.I)
STOP = re.compile(r"\b(how to use|directions|apply|shake|warning|caution|reviews?|share|"
                  r"add to cart|shipping|subscribe|you may also like|free of|free from|"
                  r"may contain|contains? no|does not contain|learn (about|more)|key ingredients|"
                  r"full ingredient|click|read more|view full|see full|ingredients? list|"
                  r"our ingredients|why we|we use|made with|made in|size|oz\b|fl\.? ?oz|ml\b|"
                  r"quantity|price|\$|not in the|\bbut\b|all of our|our products|vegan :|"
                  r"may include|may vary|varies by|one of the following)\b", re.I)


def page_text(page):
    page = re.sub(r"<script.*?</script>|<style.*?</style>|<!--.*?-->", " ", page, flags=re.S | re.I)
    page = re.sub(r"</?(p|div|li|br|tr|h\d|section|details|summary)[^>]*>", " | ", page, flags=re.I)
    page = html.unescape(re.sub(r"<[^>]+>", " ", page))
    return re.sub(r"[ \t\r\n]+", " ", page)


def looks_like_inci(token, in_run=False):
    token = token.strip(" .;*|†‡")
    if not token or len(token) > 70 or STOP.search(token):
        return False
    if INCI_WORD.search(token):
        return True
    return in_run and len(token.split()) <= 5 and bool(INCI_SHAPE.match(token))


def extract_inci(text):
    """The longest comma-separated run of ingredient-looking names, preferring
    one introduced by an "Ingredients" label."""
    best, best_score = "", 0
    labelled = [m.end() for m in LABEL.finditer(text)]
    anchors = [(a, 2) for a in labelled] + [(m.start(), 1) for m in re.finditer(r"\b(water|aqua)\b", text, re.I)]
    for start, weight in anchors[:400]:
        chunk = text[start:start + 5000]
        tokens, misses = [], 0
        for raw in re.split(r",|\s\|\s", chunk):
            tok = re.sub(r"^(and|&)\s+", "", raw.strip(" .;*|†‡"), flags=re.I)
            if looks_like_inci(tok, in_run=len(tokens) >= 3):
                tokens.append(tok)
                misses = 0
            else:
                misses += 1
                if misses >= 2 or (tokens and STOP.search(tok)):
                    break
        if len(tokens) >= MIN_TOKENS and len(tokens) * weight > best_score:
            best, best_score = ", ".join(tokens), len(tokens) * weight
    return best


def fetch_page(url):
    # Handles like "pink®-repair-masque" are legal Shopify handles but not legal
    # URLs; percent-encode the path and leave the scheme and host alone.
    scheme, rest = url.split("://", 1)
    host, _, path = rest.partition("/")
    url = f"{scheme}://{host}/{urllib.parse.quote(path, safe='/-_.~%')}"
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-US"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return r.read(3_000_000).decode("utf-8", "replace")


# --- evaluating a list ------------------------------------------------------------

# Cold-process soap lists the lye it was made from. Saponification consumes it:
# none is left in the bar, and the EU's own INCI convention for soap names the
# saponified oils. It is not a banned ingredient here, but the note below keeps
# the reason visible.
SUNSCREEN = re.compile(r"\bspf\b|sunscreen|sun screen|sunblock|sun block", re.I)
NOT_A_LIST = re.compile(r"\b(stir|drink|smoothie|servings?|capsules?|tablets?|dissolve|mix (?:with|into)|"
                        r"add to (?:water|juice)|take \d|daily dose)\b", re.I)
VARIABLE = re.compile(r"may (include|contain|vary)|varies by|one of the following", re.I)
SAPONIFIED = re.compile(r"saponified|sodium (olivate|cocoate|palmate|shea butterate|castorate|"
                        r"sunflowerate|tallowate|avocadate)|potassium (olivate|cocoate|palmate)", re.I)


def tokens_of(inci):
    return [t.strip().lower() for t in inci.split(",") if t.strip()]


def evaluate(product, inci):
    """-> (passes: bool, failures: [str], notes: [str])"""
    failures, notes = [], []
    subs = set(product.get("subs") or [])
    title = f"{product.get('title', '')} {product.get('product_type') or ''}"
    if subs & EXCLUDED_SUBS or EXCLUDED_TITLE.search(title):
        failures.append("relaxers, straighteners, permanent colour and skin bleaching "
                        "are never badged")
    if inci and NOT_A_LIST.search(inci):
        inci = ""  # what was read was directions, not a formula
    if not inci:
        failures.append("no published ingredient list")
        return False, failures, notes
    if VARIABLE.search(inci):
        failures.append("the brand says the formula varies")
    # Palau's reef-toxic sunscreen law (2020) bans phenoxyethanol in
    # sunscreens. It applies to sunscreens only, so it's checked only here.
    if SUNSCREEN.search(title) or "spf" in subs:
        hits = [t for t in tokens_of(inci) if "phenoxyethanol" in t]
        if hits:
            failures.append("phenoxyethanol in a sunscreen: banned in Palau's reef-toxic sunscreen law")
    toks = tokens_of(inci)
    for label, pattern, _source in BANNED:
        rx = re.compile(pattern, re.I)
        hits = sorted({t for t in toks if rx.search(t) and "free" not in t})
        if hits:
            failures.append(f"{label}: {', '.join(hits[:3])}")
    fragrance = [t for t in toks if FRAGRANCE.search(t) and not UNSCENTED.search(t)
                 and "essential oil" not in t]
    named = {m.group(1).lower() for m in ALLERGENS.finditer(inci)}
    named = {a for a in named if not AMBIGUOUS_ALLERGENS.match(a)}
    if fragrance and len(named) < MIN_ALLERGENS:
        failures.append("undisclosed fragrance: " + fragrance[0])
    for label, pattern in NOTED:
        rx = re.compile(pattern, re.I)
        if any(rx.search(t) for t in toks):
            notes.append(label)
    if SAPONIFIED.search(inci):
        notes.append("saponified oils (traditional soap)")
    return not failures, failures, notes


# --- scraping ---------------------------------------------------------------------

def load(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def scrape(products, store, misses, max_new):
    today = dt.date.today().isoformat()
    stale = "9999" if relaxed_lists.retry_misses() else (dt.date.today() - dt.timedelta(days=MISS_TTL_DAYS)).isoformat()
    todo = {}
    for p in products:
        url = p["url"]
        if url in store or misses.get(url, "") > stale:
            continue
        todo.setdefault(url.split("/")[2], []).append(url)
    urls = sum(len(v) for v in todo.values())
    if max_new and urls > max_new:
        # Trim evenly so one big store can't starve the others.
        per = max(1, max_new // max(len(todo), 1))
        todo = {d: u[:per] for d, u in todo.items()}
        urls = sum(len(v) for v in todo.values())
    print(f"fetching {urls} product pages across {len(todo)} stores", file=sys.stderr)
    lock = threading.Lock()
    found = [0]

    def run_store(domain):
        for url in todo[domain]:
            try:
                text = page_text(fetch_page(url))
                inci = extract_inci(text) or relaxed_lists.read(text)
            except Exception as e:  # noqa: BLE001 — one bad page must not stop the store
                print(f"  ! {url}: {str(e)[:80]}", file=sys.stderr)
                inci = ""
            with lock:
                if inci:
                    store[url] = inci
                    found[0] += 1
                else:
                    misses[url] = today
            time.sleep(DELAY)

    with concurrent.futures.ThreadPoolExecutor(STORE_WORKERS) as ex:
        list(ex.map(run_store, sorted(todo, key=lambda d: -len(todo[d]))))
    print(f"found lists on {found[0]} of {urls} pages", file=sys.stderr)


# --- main -------------------------------------------------------------------------

FAMILY_NAMES = {"hair": "Hair", "face": "Face wash", "body": "Body wash & soap",
                "skin": "Skincare", "makeup": "Makeup", "candle": "Candles"}


def apply(products, store):
    """Rewrite `clean` on every product from the stored lists. Returns the
    report inputs keyed by family."""
    stats = {f: {"eligible": 0, "listed": 0, "passed": 0} for f in FAMILY_NAMES}
    failed_by, noted_by, reasons, brands = {}, {}, [], set()
    for p in products:
        p.pop("clean", None)
        fam = family(p)
        if not fam:
            continue
        stats[fam]["eligible"] += 1
        if fam == "candle":
            ok, failures, notes = evaluate_candle(p)
            inci = "" if any(f.startswith("materials not published") for f in failures) else "materials"
        else:
            inci = store.get(p["url"], "")
            ok, failures, notes = evaluate(p, inci)
        if inci:
            stats[fam]["listed"] += 1
        if ok:
            p["clean"] = True
            stats[fam]["passed"] += 1
            brands.add(p["brand"])
            for n in notes:
                noted_by[n] = noted_by.get(n, 0) + 1
        else:
            for f in failures:
                key = f.split(":")[0]
                failed_by[key] = failed_by.get(key, 0) + 1
            if inci:
                reasons.append((fam, p["brand"], p["title"], failures))
    return stats, failed_by, noted_by, reasons, sorted(brands)


def write_report(stats, failed_by, noted_by, reasons, brands):
    total = {k: sum(s[k] for s in stats.values()) for k in ("eligible", "listed", "passed")}
    lines = ["# Marracat Clean — badge report", "",
             f"{total['eligible']} eligible products · {total['listed']} with a published "
             f"ingredient list · **{total['passed']} badged** across {len(brands)} brands.", "",
             "The standard is in catalog/clean_standard.md: nothing a major cosmetics market "
             "bans. Products without a published list are never badged.", "",
             "| Family | Eligible | With a list | Badged |", "|---|---|---|---|"]
    for fam, name in FAMILY_NAMES.items():
        s = stats[fam]
        lines.append(f"| {name} | {s['eligible']} | {s['listed']} | {s['passed']} |")
    lines += ["", "## Why products fail", "", "| Reason | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(failed_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Allowed but noted on badged products", "", "| Ingredient | Products |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in sorted(noted_by.items(), key=lambda kv: -kv[1])]
    lines += ["", "## Badged brands", "", ", ".join(brands), "",
              "## Products with a list that failed", ""]
    lines += [f"- [{fam}] {b} — {t[:70]}: {'; '.join(f)}" for fam, b, t, f in sorted(reasons)[:500]]
    REPORT.write_text("\n".join(lines) + "\n")
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scrape", action="store_true", help="fetch ingredient lists not yet stored")
    ap.add_argument("--max-new", type=int, default=0, help="cap on pages fetched this run (0 = no cap)")
    ap.add_argument("--explain", metavar="PRODUCT_ID", help="print the verdict for one product")
    args = ap.parse_args()

    catalog = json.loads(CATALOG.read_text())
    products = catalog["products"]
    store = load(STORE, {})
    misses = load(MISSES, {})

    if args.scrape:
        scrape([p for p in products if family(p) not in (None, "candle")], store, misses, args.max_new)
        STORE.write_text(json.dumps(dict(sorted(store.items())), indent=0, ensure_ascii=False) + "\n")
        MISSES.parent.mkdir(exist_ok=True)
        MISSES.write_text(json.dumps(misses))

    if args.explain:
        p = next((p for p in products if p["id"] == args.explain), None)
        if not p:
            sys.exit(f"no product {args.explain}")
        inci = store.get(p["url"], "")
        ok, failures, notes = evaluate(p, inci)
        print(f"{p['title']} ({p['brand']})\n  family: {family(p)}\n  list: {inci[:300] or '—'}\n"
              f"  verdict: {'CLEAN' if ok else 'not badged'}\n  failures: {failures}\n  notes: {notes}")
        return

    stats, failed_by, noted_by, reasons, brands = apply(products, store)
    write_catalog(CATALOG, catalog)
    total = write_report(stats, failed_by, noted_by, reasons, brands)
    print(f"clean badge: {total['passed']} badged of {total['listed']} listed "
          f"({total['eligible']} eligible) — {REPORT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
