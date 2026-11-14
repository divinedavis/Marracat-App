# Marracat App Store gallery

Seven portrait screenshots inspired by the headline-and-floating-screen layout
in the supplied Netflix App Store recording. The artwork uses Marracat's Futura
wordmark font and black, charcoal, and silver palette. All interface and product
imagery comes from the app's simulator captures; no Netflix assets are included.

- `iphone-67/`: 1320 × 2868 PNG exports.
- `iphone-65/`: 1284 × 2778 PNG exports.
- `overview.png`: review contact sheet.
- `sources/`: updated app captures. Remaining source captures are in
  `../screenshots/iphone-67/`.
- `manifest.json`: ordered filenames and benefit headlines.

Render on the project Mac with its installed Futura font and Google Chrome:

```sh
node app-store/marketing/render.cjs
```

The reference recording shows a static screenshot gallery. These assets replace
that gallery in the English (U.S.) version 1.0 App Store draft. They are not a
standalone video preview. Original screenshots remain in `../screenshots/`.

Build 35 adds catalog product photos beside purchased items in order history and
on profile checkout cards, and removes the requested personalization paragraph.
Its checkout test covers an itemized completion callback and the order image.
Tracking, refund, and cancellation processing still belong to each brand's store.

Validation on September 14, 2026: cold launch passed; the full release suite
passed 36 tests with zero failures (two opt-in real-checkout tests skipped).
Both App Store screenshot sets contain the seven files in manifest order, all
with `COMPLETE` delivery states and checksums matching the local exports.
