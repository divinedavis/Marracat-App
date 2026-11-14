# Marracat Pet Safe

The badge on a pet product means: **the listing says what the product is, and nothing in it is toxic to pets or banned anywhere.** Planned 2026-10-08 (label #10). The rules are in `catalog/pet_badge.py` and the tests in `catalog/test_pet_badge.py`.

## Food and treats

1. **Complete and balanced, or single-ingredient.** The listing states an AAFCO "complete and balanced" nutritional adequacy statement (AAFCO Model Regulations PF7) or the EU's FEDIAF "complete feed" — or it is a single-ingredient treat with that ingredient named: "Ingredients: beef liver", "100% green tripe", "single-ingredient", or one named animal part (necks, feet, ears, trachea, tripe, liver) sold air-dried, freeze-dried or raw. Multi-ingredient treats without a complete-and-balanced statement aren't badged: nobody can tell what share of a diet they're safe as.
2. **Nothing toxic to pets or banned:**

| Fails | Source |
|---|---|
| Xylitol / birch sugar | FDA consumer update "Paws Off Xylitol" (2021); ASPCA Animal Poison Control |
| Grapes, raisins, currants, sultanas | ASPCA: kidney failure in dogs |
| Onion, garlic, chives, leeks (alliums) | ASPCA: red-blood-cell damage in cats and dogs |
| Chocolate, cocoa, cacao, theobromine | ASPCA; FDA |
| Macadamia nuts | ASPCA |
| Caffeine, coffee, guarana | ASPCA |
| Alcohol | ASPCA |
| Ethoxyquin | EU Implementing Regulation 2017/962 suspended its authorisation as a feed additive |
| Propylene glycol in cat food | FDA: 21 CFR 589.1001, not generally recognised as safe in cat food |

BHA is noted, not failed: it is permitted in pet food in the US and EU.

## Grooming

Shampoos, conditioners, balms, sprays, wipes, colognes, paw and ear care: **a published ingredient list** (from the description, or the product page via `--scrape`) with nothing on Marracat Clean's ban list (`catalog/clean_standard.md`), no undisclosed fragrance, and **no essential oil toxic to cats or dogs**: tea tree (melaleuca), pennyroyal, wintergreen / methyl salicylate, cinnamon / cassia, citrus oils and d-limonene, pine, ylang-ylang, peppermint and spearmint, eucalyptus, clove, thyme, oregano, camphor, wormwood, anise, juniper and sweet birch (ASPCA Animal Poison Control; Merck Veterinary Manual, "Essential Oil Toxicosis").

## Toys, beds, bowls, collars, leashes, harnesses, clothing and tags

- **The material is named** (nylon, cotton, hemp, rope, leather, BioThane, natural rubber, silicone, stainless steel, ceramic, wool, felt…).
- **Chewables and bowls**: plastic, rubber or vinyl that a pet chews or eats from must be stated BPA- and phthalate-free (or "non-toxic" / "food-grade"). BPA and phthalates are restricted in food-contact and children's articles in the EU (Reg. 2024/3190; REACH Annex XVII entries 51-52).
- **No PVC or vinyl** unless stated phthalate-free (REACH Annex XVII entry 51).

## What's judged

The pets department. Merch for people (T-shirts, hoodies, mugs, stickers, books, gift cards) isn't judged; a pet hoodie is. Read from each product's own title, description, tags and options.
