# Marracat Lab Verified

The badge on a wellness product you swallow means: **the listing names a third-party programme that tested the finished product, or publishes an independent lab's certificate of analysis, and nothing in it is banned in any country.** Planned 2026-10-08 (label #9); the owner's rule for every label is "nothing banned in any country". The rules are in `catalog/lab_badge.py` and the tests in `catalog/test_lab_badge.py`.

## The rules

1. **A named programme or a published COA.** One of:
   - NSF Certified for Sport, NSF/ANSI 173, or "NSF certified" for the product. An *NSF-registered facility* or "GMP certified" is an audit of the plant, not a test of the product, so it doesn't count.
   - USP Verified (USP Dietary Supplement Verification Program).
   - Informed Sport or Informed Choice (LGC).
   - BSCG Certified (Banned Substances Control Group).
   - Clean Label Project certification.
   - A certificate of analysis or lab results the brand publishes, from a lab the listing calls third-party, independent or ISO 17025 accredited (or names, e.g. Eurofins).
2. **"Third-party tested" alone isn't enough.** A claim with no programme or lab named can't be checked; it is counted in the report, not passed.
3. **Nothing banned anywhere:**

| Fails | Where it is banned or restricted |
|---|---|
| DMAA, DMHA (octodrine) | FDA: DMAA is not a lawful dietary ingredient (Import Alert 54-11, 2013); DMHA warning letters 2019; banned in Canada, Australia and New Zealand; WADA S6 |
| Ephedra / ephedrine alkaloids (ma huang) | US: 21 CFR 119.1 (2004) declares supplements with ephedrine alkaloids adulterated; EU Reg. 2019/650 lists ephedra in Annex III Part A of Reg. 1925/2006 (prohibited in food) |
| Sibutramine | Marketing authorisation withdrawn in the EU and US (2010) |
| Tianeptine | FDA warnings (2018, 2022, 2025); banned in Alabama, Michigan, Ohio, Tennessee and other states |
| Phenibut | FDA: not a lawful dietary ingredient (warning letters 2019); Australia Poisons Standard Schedule 9 (2018); controlled in Hungary, Italy and Lithuania |
| Kratom (mitragynine, 7-OH) | Australia Schedule 9; controlled in Denmark, Poland, Sweden and the UK (Psychoactive Substances Act 2016); banned in Alabama, Arkansas, Indiana, Rhode Island, Vermont and Wisconsin |
| Yohimbe / yohimbine | EU Reg. 2019/650 places yohimbe under Union scrutiny (Reg. 1925/2006 Annex III Part C); prescription-only in the UK and Australia (Schedule 4) |
| Higenamine | WADA Prohibited List S3 (beta-2 agonist); FDA warning letters 2019 |
| DHEA | Prescription-only in Canada (Prescription Drug List), Australia (Schedule 4) and EU member states; WADA S1 |
| Kava | Banned in food in the UK (Kava-kava in Food (England) Regulations 2002); restricted elsewhere in the EU |
| Comfrey, taken internally | FDA (2001) advised removing it from dietary supplements (pyrrolizidine alkaloids); Canada and Australia restrict internal use |
| CBD, THC, delta-8 / delta-9 / delta-10, HHC | FDA: excluded from the dietary-supplement definition (21 USC 321(ff)(3)(B)); CBD in food is an unauthorised novel food in the EU and UK; banned outright in Hong Kong (2023); delta-8 THC banned or restricted in more than 20 US states |

Claims of absence ("CBD-free", "no ephedra") are removed before the bans are looked for.

## What's judged

Products in the wellness department that are swallowed: capsules, tablets, gummies, powders, teas, tinctures, extracts, bitters, sea moss, vitamins and other supplements. Deodorants, lubricants, balms and other topicals, devices, books and merch aren't judged. Read from each product's own title, description and tags; nothing is fetched, so a certification shown only as an image on the product page isn't seen.
