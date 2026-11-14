# Marracat App Store gallery + preview (Ralph Lauren style, 2026-09-24)

Modelled on Ralph Lauren's App Store listing: an app-preview video first, then
screenshots over one soft landscape that runs across every panel, with serif
title-case headlines and the real screen in a card with a thin white outline.
Departments on show: hair, home, jewelry, fragrance, plus browse and cart.
Not only clothes.

- `raw/`: 1320x2868 stills from `AppStoreTourUITests` (opt-in).
- `iphone-69/`: seven 1320x2868 panels (APP_IPHONE_67 slot). `make_gallery.py`.
- `raw-ipad/` + `ipad-13/`: the same tour on an iPad Pro 13-inch sim (2026-09-27, when the app went universal); eight 2064x2752 panels for the APP_IPAD_PRO_3GEN_129 slot via `make_gallery.py --ipad`. Panel 5 uses the candle results capture (the detail shot's photo hadn't loaded).
- `preview/marracat-preview-886x1920.mp4`: 27 s, 30 fps H.264, silent stereo
  AAC, 886x1920 (the 6.9"/6.7" app-preview size). `cut.py` is the edit list.

Regenerate:

```sh
# 1. record the tour (free iPhone 17 Pro Max sim, status bar overridden to 9:41)
xcrun simctl io <UDID> recordVideo --codec=h264 --force tour.mov &
TEST_RUNNER_MARRACAT_TOUR=1 TEST_RUNNER_MARRACAT_SHOT_DIR=$PWD/raw \
  xcodebuild test -scheme Marracat -destination id=<UDID> \
  -only-testing:MarracatUITests/AppStoreTourUITests
# stop the recording with SIGINT
# 2. constant frame rate first (the sim recording is VFR; trimming it directly
#    produced a 50 s file), then cut
ffmpeg -i tour.mov -vf "fps=30,scale=886:-2,crop=886:1920:0:(ih-1920)/2" -crf 12 cfr.mp4
python preview/cut.py      # segment times are for the 2026-09-24 recording
# 3. screenshots
python make_gallery.py
```

Uploaded 2026-09-24 to version 1.1 (6.7" screenshots; the 6.5" set was deleted so every size uses these). The preview video was uploaded, then removed at the owner's request the same day; the file stays here unused.

## iPhone Duo (2026-10-14) — staged, NOT uploaded

- `raw-duo/`: 1398x2034 stills from `AppStoreTourUITests` on the **iPhone Duo
  outer display** (Xcode 27.1 RC's iOS 27.1 simulator, status bar 9:41). They
  come from a build made with the iOS 27.1 SDK, which is what fills the Duo's
  screens; the build on TestFlight is made with Xcode 26.6 and shows letterboxed
  to the left of the Duo's status column (Apple, "Preparing your app for iPhone
  Duo"). So these show the app as it will look once it ships with Xcode 27.1.
- `iphone-duo/`: five 1398x2034 panels in the Pinterest dark style
  (`scripts/make_pinterest_screenshots.py duo-pinterest.json`; the script takes
  `"size"` and `"status_bar"` for Duo).
- ASC display type: `APP_IPHONE_DUO` (accepted by the API; Find A Crib 1.2.9
  uses it; Apple's OpenAPI spec 4.5.1 doesn't list it yet). Apple requires Duo
  screenshots from April 2027 and badges the product page "optimized for iPhone
  Duo" when they're present, so upload them with the first version whose build
  is made with Xcode 27.1, not before:

      ~/.venvs/marracat/bin/python scripts/upload_app_store_screenshots.py \
        --localization <next version's en-US localization id> \
        --display-type APP_IPHONE_DUO app-store/gallery/iphone-duo/*.png

- Inner display (2007x2853) set: not made. Opening the Duo simulator needs
  Device Hub, which needs macOS 26.6 (this Mac runs 26.4.1); simctl and
  XCUIDevice have no fold control, and the simulator boots closed.
