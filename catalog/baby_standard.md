# Marracat Baby Safe

The badge on a baby product means: **the listing says exactly what the product is made of, and none of it is banned for children's products in any country.** The rules are in `catalog/baby_badge.py` and the tests in `catalog/test_baby_badge.py`. The owner set the rule on 2026-10-08: "make sure no ingredient is banned in any country".

A listing that states neither ingredients nor materials is never badged. Strollers, car seats, carriers, cribs, monitors, books, stickers and gift cards aren't judged. Neither are products for parents, such as nursing bras and nipple cream.

## Formulas (washes, lotions, oils, balms, diaper creams, wipes, powders)

- **A full published ingredient list is required.** It's read from the product's description, or from its page by `baby_badge.py --scrape`.
- **It must pass the Marracat Clean ban list** (`catalog/clean_standard.md`): nothing banned in any major cosmetics market.
- **No fragrance of any kind:** no "fragrance" or "parfum", no named EU fragrance allergens (linalool, limonene and so on), and no essential oils, even named ones like lavender or tea tree.
  - The EU's Scientific Committee on Consumer Safety names fragrance allergens as the leading cause of contact allergy, and infants' skin barrier is still developing.
  - The American Academy of Pediatrics' HealthyChildren.org advises against using essential oils on babies.
  - Unscented baby products are what dermatologists recommend for eczema-prone infants.
- **Rules for children under 3:**

| Ingredient | Rule |
|---|---|
| Salicylic acid (except in shampoo) | EU Cosmetics Regulation 1223/2009 Annex III entry 98: not for children under 3, except shampoos |
| Methylisothiazolinone / methylchloroisothiazolinone | Banned in EU leave-on cosmetics (Reg. 2016/1198); on Canada's Cosmetic Ingredient Hotlist |
| Talc | EU Annex III entry 59 requires "keep powder away from children's nose and mouth". Canada proposed inhalation-hazard labelling (2021). The Marracat standard excludes it from baby products. |
| Boric acid and borates | EU Annex III entry 1a: not for children under 3 |

## Feeding and teething (bottles, cups, plates, bowls, spoons, teethers, pacifiers, clips, place mats)

The material must be named. Silicone, stainless steel, glass, natural rubber, solid wood and ceramic qualify. Plastic qualifies only when the listing also says it's BPA-free.

| Fails | Where it is banned |
|---|---|
| Polycarbonate / BPA | BPA is banned in baby bottles in the EU (Directive 2011/8/EU), the US (FDA, 2012) and Canada (2010), and in all EU food-contact materials from 2026 (Reg. 2024/3190) |
| Melamine or bamboo-fibre plastic | The EU bars plastic food-contact articles with bamboo filler (Commission, 2021, under Reg. 10/2011) |
| PVC / vinyl / phthalates | Phthalates are restricted in childcare articles in the EU (REACH Annex XVII entries 51–52) and the US (CPSIA §108, 16 CFR 1307) |
| Lead or cadmium | CPSIA limits lead in children's products to 100 ppm; EU REACH Annex XVII entry 23 restricts cadmium |

## Textiles (clothing, swaddles, blankets, bedding, cloth diapers, bibs)

- **Fibre:** a natural or certified fibre must be named: cotton, organic cotton, linen, wool, merino, silk, hemp or cashmere, or GOTS / OEKO-TEX.
- **Not enough on its own:** polyester, nylon, PUL and fleece; and bamboo viscose or rayon, which the FTC requires be called rayon because it is regenerated, not natural.
- **Banned treatments fail:**

| Fails | Where it is banned |
|---|---|
| Flame retardants | California AB 2998 (2020) bans them in juvenile products, mattresses and upholstery; the EU POPs Regulation bans PBDEs |
| PFAS treatment | California AB 1817 bans intentionally added PFAS in textiles from 2025; New York bans PFAS in apparel (2024) |
| PVC / phthalates, lead, cadmium | As for feeding articles |

## Toys for under-3s

The material must be named: solid wood, food-grade silicone, organic cotton, natural rubber or wool felt. No PVC, phthalates, lead or cadmium.

## Claims of absence

"Free of BPA, PVC and phthalates", "does not contain flame retardants" and "no PFAS" are claims of absence. They are removed before the bans are looked for, so they never count as hits. Fibre and material words are still read from the full listing.

## Known limits

- The badge reads what the listing says; it doesn't test the product.
- A listing that names a good material without saying the whole product is made of it ("silicone tip") can pass. The report lists badged brands so they can be spot-checked.
