# Marracat True Metal — the standard

A jewelry badge, approved by the owner on 2026-10-08 as the first of the
quality labels that follow Marracat Clean. It says one thing: **every metal the
listing names is a real, solid, skin-safe metal, and nothing is plated or
toned to look like a metal it isn't.** A second tier, **Marracat True Metal ·
Ethically Sourced**, adds that the brand states where the metal or stones come
from in a way a scheme can back up.

The scanner is `catalog/metal_badge.py`; the report it writes is
`catalog/metal_report.md`; the tests are `catalog/test_metal_badge.py`. It reads
what the brand publishes about the product: title, description, tags and
product type. A listing that doesn't name its metal is never badged.

## Metals that qualify

| Metal | How the listing must say it | Why it's real |
|---|---|---|
| Gold, 10 karat or more | "10k", "14k", "18k", "22k", "24k", "14 karat", "solid gold" | In the US, metal under 10 karat may not be called gold, and "14k gold" unqualified means solid gold of that karat; plating must be disclosed (FTC Jewelry Guides, 16 CFR §23.4) |
| Sterling silver | "sterling silver", "925", ".925", "fine silver", "999 silver", "Argentium" | Sterling means at least 92.5% silver (FTC 16 CFR §23.6; National Gold and Silver Stamping Act, 15 U.S.C. §§291–300) |
| Platinum | "platinum" | FTC 16 CFR §23.7 |
| Implant-grade steel | "316L", "surgical steel", "implant-grade steel" | The steel the Association of Professional Piercers accepts for fresh piercings (ASTM F138) |
| Titanium, niobium | "titanium", "niobium" | Nickel-free metals used for body jewelry (APP initial-jewelry standard; ASTM F136 / F67 titanium) |

Plain "stainless steel" with no grade is **not** badged: common grades such as
304 contain 8–10% nickel, and the listing doesn't say which one it is. It
qualifies when the listing also says "nickel-free".

Other materials (beads, wood, stones, leather, resin) don't stop the badge.
A beaded earring on sterling silver ear wires is badged: the metal it names is
true.

## What fails

- **Base metals:** brass, copper, bronze, zinc, pewter, aluminium, iron, tin,
  "alloy" (except "gold alloy" / "silver alloy" / "platinum alloy"), "base
  metal", and nickel unless the listing says "nickel-free".
- **Coatings presented as metal:** plated, plating, electroplated, gold-tone,
  silver-tone, dipped, coated, PVD, IP-plated, flashed. The one exception is
  **rhodium** plating over sterling silver, white gold or platinum: it is the
  standard finish for those metals, not a disguise.
- **Gold-filled and vermeil:** noted, not badged. Both are real FTC terms
  (gold-filled is a layer of at least 10k gold bonded to a base metal, at least
  1/20 of the weight; vermeil is at least 10k gold, 2.5 microns thick, over
  sterling silver, 16 CFR §23.5). Both are a gold layer that wears through to
  something else, so the gold the shopper sees isn't the piece's metal.
- **Imitation:** faux, imitation, costume, "fashion jewelry".
- **Lead or cadmium named** in any way other than "lead-free" / "cadmium-free".
  The qualifying metals meet every jewelry limit there is: EU REACH Annex XVII
  entry 63 (lead below 0.05% by weight in jewellery) and entry 23 (cadmium
  below 0.01% in metal parts); the US CPSIA limit of 100 ppm lead in children's
  products; California's lead-in-jewelry law (Health and Safety Code
  §§25214.1–25214.4.2) and its 0.03% cadmium limit for children's jewelry
  (SB 646). A listing that names lead or cadmium as a material fails.
- **Nickel release:** the EU limits how much nickel a piece may release
  (REACH Annex XVII entry 27: 0.2 µg/cm²/week for piercing posts, 0.5 for
  pieces in long skin contact). The qualifying metals meet it; a listing that
  names nickel as a material fails.
- **No metal named:** not badged.

When a listing names a qualifying metal **and** a failing term, it fails. "18k
gold plated brass" is brass; "sterling silver plated" is plating. The scanner
is conservative on purpose: a wrong badge costs more than a missing one.

## Ethically Sourced tier

Awarded to a True Metal product when the listing names one of these:

| Claim | Backed by |
|---|---|
| Recycled gold, silver or metal | the recycled content claim the brand makes |
| Fairmined gold | Alliance for Responsible Mining, Fairmined Standard |
| Fairtrade gold | Fairtrade International Gold Standard |
| Responsible Jewellery Council / RJC certified | RJC Code of Practices certification |
| Lab-grown or lab-created diamonds or stones | FTC 16 CFR §23.12 (lab-grown must be disclosed as such) |
| Conflict-free / Kimberley Process stones | Kimberley Process Certification Scheme |

A bare "ethically sourced" or "responsibly made" with no scheme or material
behind it is not enough. "Lab" on its own (as in "IGI lab certificate", a
grading report for a natural stone) is not lab-grown.

## Sources

- FTC Guides for the Jewelry, Precious Metals, and Pewter Industries, 16 CFR Part 23 — https://www.ecfr.gov/current/title-16/chapter-I/subchapter-B/part-23
- National Gold and Silver Stamping Act, 15 U.S.C. §§291–300
- EU REACH Annex XVII, entries 23 (cadmium), 27 (nickel), 63 (lead) — https://echa.europa.eu/substances-restricted-under-reach
- US Consumer Product Safety Improvement Act, lead in children's products — https://www.cpsc.gov/Business--Manufacturing/Business-Education/Lead
- California Health and Safety Code §§25214.1–25214.4.2 (lead and cadmium in jewelry)
- Association of Professional Piercers, initial jewelry standards — https://safepiercing.org/jewelry-for-initial-piercings/
- Fairmined Standard — https://fairmined.org ; Fairtrade Gold — https://www.fairgold.org
- Responsible Jewellery Council — https://www.responsiblejewellery.com
- Kimberley Process — https://www.kimberleyprocess.com
