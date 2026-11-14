# Marracat Natural Home

The badge on a home product means: **the listing names its main material, and that material is natural or certified, with nothing banned anywhere.** Planned 2026-10-08 (label #6). The rules are in `catalog/home_badge.py` and the tests in `catalog/test_home_badge.py`.

## Textiles

Rugs, throws, blankets, pillows, bedding, towels, table linens, curtains. Passes when:
- a stated composition is **at least 90% natural fibre** (the parser and threshold Marracat Natural Fiber uses, `catalog/fiber_standard.md`; viscose, modal, lyocell and bamboo viscose are regenerated, not natural); or
- one natural fibre is named (cotton, linen, wool, silk, jute, hemp, sisal, seagrass, mudcloth) with no synthetic or regenerated fibre beside it; or
- the textile is **OEKO-TEX Standard 100 or GOTS** certified.

## Tableware and kitchen

Mugs, glasses, plates, bowls, serveware, utensils, cookware. Passes when the main material is glass, stainless steel, cast iron, solid wood, stone or marble — or **ceramic, stoneware, porcelain or earthenware stated lead-free**.

| Fails | Why |
|---|---|
| Ceramic tableware not stated lead-free | Lead leaches from glazes into food and drink. The FDA sets action levels for lead in ceramicware (Compliance Policy Guide Sec. 545.450) and California Prop 65 (Cal. Code Regs. tit. 27 §25805) requires a warning above its limits; "lead-free", "lead and cadmium free" or "Prop 65 compliant" passes |
| Lead crystal | The same lead-leaching concern (Prop 65 listed) |
| Bamboo-fibre melamine | Plastic with bamboo filler is barred from EU food contact (Regulation 10/2011; Commission statement 2021) |
| Melamine, plastic, acrylic, resin as the only material | Not natural |

## Décor and furniture

Baskets, vases, lighting, furniture and décor pass when a natural material is named: solid wood (oak, walnut, acacia, mango, teak and others, reclaimed wood, solid bamboo), rattan, wicker, seagrass, jute, raffia, stone or marble, ceramic, glass, linen, cotton, wool — or a solid metal (cast or wrought iron, brass, copper, stainless steel), which is noted.

| Fails | Why |
|---|---|
| MDF, particleboard, plywood, engineered or composite wood not stated CARB Phase 2 or TSCA Title VI compliant | Formaldehyde emissions from composite wood are limited by California's Airborne Toxic Control Measure (CARB Phase 2, 17 CCR 93120) and the US TSCA Title VI (40 CFR Part 770); a product not stated compliant can't be shown to meet them |
| PVC or vinyl not stated phthalate-free | EU REACH Annex XVII entry 51 |
| Plastic, resin or acrylic with no natural material named | Not natural |

## Tier

"Marracat Natural Home · Certified": organic or GOTS textiles, or FSC-certified wood (Forest Stewardship Council).

## What's judged

The home department, minus candles (judged by Marracat Clean's candle rules, `catalog/candle_badge.py`), incense, diffusers and room sprays, wall art and prints, games, gift cards, food and personal-care items. Read from each product's own title, description, tags and options; nothing is fetched.
