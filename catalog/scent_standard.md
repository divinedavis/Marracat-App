# Marracat Clear Scent — the standard

The blue-violet **Marracat Clear Scent** mark goes on a worn fragrance (perfume,
eau de parfum or toilette, cologne, body or hair mist, perfume oil, solid
perfume) when the brand publishes an ingredient list and that list shows
three things:

1. **Nothing banned in any country.** Every ingredient on Marracat Clean's ban
   list (catalog/clean_standard.md) fails, plus the fragrance bans below. The
   owner's rule (2026-10-08) is that no ingredient banned anywhere may carry a
   Marracat badge, so the strictest market wins.
2. **No phthalates, of any kind.** The badge promises phthalate-free.
3. **The scent is disclosed.** "Fragrance" or "parfum" passes only with the EU
   fragrance allergens it contains named beside it (at least two, as Clean
   requires), or the formula is made of named essential oils and isolates.

A fragrance with no published list is never badged. It is a check on what the
brand publishes, not a lab test.

## What can carry it

Category `fragrance` in the catalog, when the listing is a worn fragrance (the
`perfume-oil`, `edp`, `edt`, `cologne`, `body-mist` or `refill` aisles, or a
title or type naming one). Not badged: candles (Marracat Clean's candle rule,
catalog/candle_badge.py), home fragrance (diffusers, burner oils, room and
linen sprays, wax melts, incense), and sets, samplers and discovery boxes,
which hold several formulas one list can't vouch for. Scented bath and body
products are cosmetics and get Marracat Clean instead.

## Fragrance bans, beyond Clean's list

| Ingredient | Why it fails | Source |
|---|---|---|
| Musk tibetene, musk moskene | Banned | EU Cosmetics Regulation 1223/2009 Annex II (entries 413, 414); IFRA prohibited |
| Musk ambrette, musk ketone, musk xylene | Already on Clean's list | EU Annex II (ambrette); EU Ecolabel and Target Clean exclude nitro musks |
| Atranol, chloroatranol | Banned since 23 August 2021 | EU Reg. 2017/1410 (Annex II); IFRA prohibited |
| Lilial (butylphenyl methylpropional), Lyral (HICC) | Already on Clean's list | EU Annex II since 2022 and 2021 |
| Methyl eugenol | Restricted to trace levels | EU Annex III caps it at 0.01% in fine fragrance; Health Canada's Cosmetic Ingredient Hotlist restricts it. A list can't show the level, so a named addition fails |
| AETT (versalide) | Banned | EU Annex II; IFRA prohibited (neurotoxic) |
| 7-Methylcoumarin | Banned | EU Annex II; IFRA prohibited |
| Diethyl maleate, dihydrocoumarin | Prohibited | IFRA Standards (sensitisers) |
| Benzene | Banned | EU Annex II; carcinogen |

## Phthalates

DEHP, DBP and BBP are on EU Annex II (CMR 1B) and banned in children's
products in the US (CPSIA). **Diethyl phthalate (DEP)**, the one perfumers
actually used as a solvent, is *not* banned anywhere: the EU, the US and
Canada all permit it. It still fails here, because the mark promises
phthalate-free and Marracat Clean already fails any phthalate (Helm et al.
2018 found DEP in hair products marketed to Black women).

## Fragrance disclosure

The EU names 80+ fragrance allergens that must appear on the label from 31
July 2026 (Reg. 2023/1545); California's Fragrance and Flavor Ingredient Right
to Know Act (2020) requires disclosure of fragrance ingredients on the state's
hazard lists. A list that says "fragrance" and names fewer than two allergens
(menthol, camphor, benzyl benzoate and the like don't count on their own) has
not disclosed its scent. "Essential oil or fragrance oil" counts as undisclosed:
it may be the fragrance oil.

Denatured alcohol is allowed and noted.

The scanner is catalog/scent_badge.py; lists are stored with Clean's in
catalog/ingredients.json; the latest counts are in catalog/scent_report.md.
