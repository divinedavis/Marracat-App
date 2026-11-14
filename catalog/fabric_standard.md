# Marracat Safe Fabric

The badge on a garment means: **the listing states what the garment is made of, names no treatment that is banned anywhere, and the garment is less than half synthetic (or the fabric is certified tested for banned substances).** The owner set the rule on 2026-10-08: "clothes that don't include any harmful synthetic materials that are banned anywhere". The rules are in `catalog/fabric_badge.py` and the tests in `catalog/test_fabric_badge.py`.

## The rules

1. **A composition must be stated**, read by the same parser as Marracat Natural Fiber (`catalog/fiber_badge.py`). No composition, or one that doesn't add up, no badge.
2. **No treatment banned anywhere:**

| Fails | Where it is banned or restricted |
|---|---|
| PFAS / fluorocarbon finishes (PFAS, PFC, PFOA, PFOS, C6/C8, Teflon, Scotchgard) | California AB 1817 (Health & Safety Code §108970) bans intentionally added PFAS in textiles from 1 Jan 2025; New York S6291A bans PFAS in apparel from 31 Dec 2024; EU REACH Annex XVII entry 68 (PFOA and related) and entry 79 (PFHxA, Reg. 2024/1328) restrict them in textiles |
| A water-repellent (DWR) or stain-resistant finish not stated PFAS-free | Most DWR finishes were fluorinated, so an unstated chemistry can't be shown to meet the laws above. "PFC-free", "PFAS-free" or "C0" passes |
| Flame-retardant finishes | EU POPs Regulation (EU) 2019/1021 bans PBDEs and other brominated flame retardants; California AB 2998 (2020) bans flame retardants in children's products, mattresses and upholstered furniture |
| Antimicrobial / anti-odour biocide treatments | Triclosan isn't approved under the EU Biocidal Products Regulation 528/2012 (Implementing Decision (EU) 2016/110), so articles treated with it can't be sold in the EU; an undisclosed biocide can't be shown not to be one |
| PVC / vinyl not stated phthalate-free | REACH Annex XVII entry 51 (Reg. 2018/2005) restricts DEHP, DBP, BBP and DIBP, the usual PVC plasticisers, to 0.1% in all articles, clothing included |

3. **Less than half synthetic.** Polyester (incl. recycled), nylon, acrylic, elastane, polyurethane, polypropylene, PVC and metallic fibres together must be under 50% of the stated composition. Synthetic fibres themselves aren't banned anywhere; this is the Marracat line for "no harmful synthetics", set at a majority so a 60/40 cotton–poly hoodie passes and a 50/50 one doesn't.
4. **Certification overrides the synthetic limit.** A listing that states OEKO-TEX Standard 100, bluesign or GOTS certification passes rule 3 at any synthetic share. Those standards lab-test the finished fabric for the banned substances in the next section.

Regenerated cellulose (viscose, modal, lyocell) isn't counted as synthetic, but is noted.

## What a listing can and can't show

| Substance | Banned by | Visible in a listing? |
|---|---|---|
| Azo dyes that release carcinogenic aromatic amines | REACH Annex XVII entry 43 | No: lab-tested |
| Nonylphenol ethoxylates (NPEs) | REACH Annex XVII entry 46a (Reg. 2016/26), 0.01% in textiles washed in water | No: lab-tested |
| DMF (dimethylformamide) in coated fabrics and PU | REACH Annex XVII entry 76 (Reg. 2021/2030) | No: lab-tested |
| Residual PFAS | CA AB 1817, NY S6291A, REACH entries 68/79 | Only if the finish is named |
| PVC phthalates | REACH Annex XVII entry 51 | Only if PVC is named |

For the "No" rows, the badge relies on either a stated certification (OEKO-TEX Standard 100, bluesign and GOTS all test for them) or a mostly natural composition (NPEs and DMF come with synthetic processing and coatings). It doesn't claim a lab test of every garment.

## What's judged

Clothing only, as for Marracat Natural Fiber: shoes and accessories aren't judged, and neither are gift cards, stickers, prints, mugs, tote bags or digital patterns.
