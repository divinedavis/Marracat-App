# Marracat Safer Clean — the standard

The green **Marracat Safer Clean** mark goes on a household cleaner, laundry or
dish product when the brand publishes an ingredient list and nothing on
it is banned in any country (the owner's rule, 2026-10-08), with its fragrance
disclosed. It is a check on what the brand publishes, not a lab test.

A product with no published list is never badged. California's Cleaning
Product Right to Know Act (SB 258, 2017) has required cleaning products sold
there to list their intentionally added ingredients online since 2020, so a
missing list is a real gap, not an inconvenience.

## What can carry it

Category `household` in the catalog, when the listing is a cleaning formula:
the `laundry`, `cleaners`, `fabric-care` or `dish` aisles, or a title naming a
detergent, cleaner, dish soap, dishwasher product, stain remover, fabric
softener or the like. Not badged: tools (brushes, sponges, cloths, mops,
gloves, dryer balls, bottles), paper goods, air fresheners and room sprays, and
hand soap and sanitiser, which are personal care and get Marracat Clean.

## What fails

Everything on Marracat Clean's ban list (catalog/clean_standard.md: formaldehyde
and its releasers, parabens, phthalates, isothiazolinones, EDTA, SLS/SLES,
microplastics, and the rest), plus:

| Ingredient | Why it fails | Source |
|---|---|---|
| Chlorine bleach (sodium or calcium hypochlorite, chloroisocyanurates) | Excluded from eco-certified cleaners; toxic gas with acids or ammonia | EU Ecolabel criteria for detergents and cleaners exclude reactive chlorine (Decisions (EU) 2017/1217, 2017/1218, 2017/1219) |
| Phosphates and phosphonates | Capped or banned for consumer detergents | EU Reg. 259/2012 (phosphorus limits in consumer laundry and automatic dishwasher detergents); 17 US states banned phosphates in dishwasher detergent in 2010 |
| Nonylphenol and octylphenol ethoxylates | Banned in cleaning products | EU REACH Annex XVII entry 46 |
| Triclosan, triclocarban | Banned in cleaning products | Minnesota Statutes 145.945 (2017); triclosan not approved for hygiene biocides in the EU (Decision (EU) 2016/110) |
| PFAS (perfluoro-, polyfluoro-, fluorotelomer, PTFE, fluorosurfactants) | Banned when intentionally added | Minnesota's Amara's Law, cleaning products from 1 January 2025; Maine from 2026 |
| 1,4-Dioxane | Capped | New York ECL 35-0105: 1 ppm in household cleansing products from 2023 |
| Borax, boric acid, sodium perborate and other borates | Toxic to reproduction | EU CLP classification Repr. 1B; REACH Annex XVII entries 28-30 bar such substances from mixtures sold to the public above the classification limit. A list can't show the level, so a named borate fails |
| Undisclosed fragrance | Not disclosed | California's Cleaning Product Right to Know Act requires fragrance allergens on the EU list to be disclosed; the same two-allergen rule as Clean. "Essential oil or fragrance oil" counts as undisclosed |

## Allowed but noted

- **Quaternary ammonium compounds (quats: benzalkonium chloride and kin).**
  Not banned anywhere: the EU approves several under the Biocidal Products
  Regulation, and the US EPA registers them as disinfectants. They are linked
  to occupational asthma, and the EU Ecolabel admits only readily
  biodegradable quats. The rule bars what is banned somewhere, so quats are
  noted, not failed.
- **Optical brighteners (stilbenes, "whitening agents").** Not banned anywhere.
  The EU Ecolabel limits them in some laundry detergents for their poor
  biodegradability. Noted, not failed.

The scanner is catalog/safer_clean_badge.py; lists are stored with Clean's in
catalog/ingredients.json; the latest counts are in catalog/safer_clean_report.md.
