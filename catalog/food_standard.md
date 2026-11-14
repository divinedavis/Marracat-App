# Marracat Clean Food

The badge on a food or drink means: **the brand publishes its ingredient list, and nothing on it is banned as a food additive in any country.** On top of that, the Marracat standard leaves out high-fructose corn syrup, which no country bans. The rules are in `catalog/food_badge.py` and the tests in `catalog/test_food_badge.py`. The owner set the rule on 2026-10-08: "make sure the product doesn't include any banned ingredients in any country".

## What it covers

Packaged foods, snacks, sauces, spices, baking mixes, spreads, drinks, teas and coffee (category `grocery`). Never judged:
- **Alcohol:** it has its own category.
- **Supplements:** capsules, vitamins, protein powders and CBD.
- **Pet food.**
- **Merchandise:** mugs, infusers, kettles, gift cards and apparel.

## A list is required

A food without a published ingredient list is never badged. A list is read from the product's own description first: the run after an "Ingredients:" label, up to the next section. The next section is the first of these:
- a new sentence
- "Contains:", an allergen statement or nutrition facts
- directions, storage, brewing instructions, net weight or "Product Details"

Sub-lists such as "Enriched flour (wheat flour, niacin, iron)" stay with their item. A one-ingredient tea ("Ingredients: organic burdock root") is a complete list. Marketing copy after the label ("Features red pepper for bold flavor") is not a list. When a description has no list, `food_badge.py --scrape` reads the product page and stores what it finds in `catalog/ingredients.json`.

## Banned somewhere: fails

| Ingredient | Where it is banned |
|---|---|
| Red No. 3 (erythrosine, E127) | US FDA revoked its food authorisation (January 2025); California Food Safety Act AB 418 (2023) bans it from 2027 |
| Red 40, Yellow 5, Yellow 6, Blue 1, Blue 2, Green 3, Citrus Red 2, Orange B and their lakes; unnamed "artificial colors" | West Virginia HB 2354 (2025) bans these synthetic dyes in food sold in the state from 2028. Green 3 (E143) is not authorised in the EU (Reg. 1333/2008 Annex II). "Artificial colors" fails because, in the US, those words mean these dyes. |
| Titanium dioxide (E171) | Banned as a food additive in the EU since August 2022 (Commission Regulation 2022/63) |
| Potassium bromate (bromated flour) | Banned in the EU, UK, Canada, China and Brazil; California AB 418 from 2027 |
| Brominated vegetable oil (BVO) | US FDA revoked its authorisation (2024); never permitted in the EU or Japan |
| Azodicarbonamide | Not permitted in the EU (Directive 2004/1/EC) or Australia/New Zealand; banned in Singapore |
| Propylparaben (E216) | Removed from the EU additive list (2006); California AB 418 from 2027 |
| Partially hydrogenated oils | US FDA removed their GRAS status (2018); Canada banned them (2018); the EU caps industrial trans fat at 2 g per 100 g of fat (Reg. 2019/649) |
| rBST/rBGH dairy | The hormone is banned in Canada, the EU, Japan, Australia and New Zealand |
| Cyclamate | Banned in US foods since 1969 (21 CFR 189.135) |
| Olestra | Not authorised in the EU or Canada |
| Sudan dyes, rhodamine, para red | Illegal food dyes everywhere |

## Excluded by the Marracat standard

| Ingredient | Why |
|---|---|
| High-fructose corn syrup (glucose-fructose syrup, isoglucose) | Not banned anywhere. The owner listed it for exclusion on 2026-10-08. |

## Allowed but noted

These are legal everywhere, and the report counts them:
- **BHA/BHT:** permitted in the EU (E320/E321) and the US. California lists BHA under Prop 65, a warning rather than a ban.
- **Caramel colour.**
- **Carrageenan:** the EU bars it only in infant formula.
- **Sodium nitrite.**

A claim of absence ("no high-fructose corn syrup", "dye-free") is never read as an ingredient.

## Known limits

- A list is only as good as the brand's label. The badge reads what is published; it doesn't test the food.
- "Natural flavors" are allowed: they are legal everywhere, and they are not dyes.
- A state or national ban added after this standard needs adding to `FOOD_BANNED` with its source.
