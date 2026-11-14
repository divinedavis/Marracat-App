# App Store release preparation — September 16, 2026

**Version 1.0 is submitted to App Review.** Build 38, review submission
`b97b5d17-f30d-4407-b44e-5b644acbfa3c`, state `WAITING_FOR_REVIEW`. Release type
is `AFTER_APPROVAL`, so approval will not put it on the store — releasing stays a
deliberate action.

The last blocker was `STATE_ERROR.APP_DATA_USAGES_REQUIRED`. The App Privacy
answers were published on September 16 — eight data types, the entries recorded
in [app-privacy-answers.md](app-privacy-answers.md). Apple's validation passed
immediately afterward.

Check state or resubmit after a rejection with
`~/.venvs/marracat/bin/python scripts/submit_for_review.py` (validate only) and
`--submit`.

Two things the API teaches that are not in Apple's docs: attaching a version to a
draft submission moves it from `PREPARE_FOR_SUBMISSION` to `READY_FOR_REVIEW`
while still unsubmitted, and `/reviewSubmissions/{id}/items` omits its
`appStoreVersion` linkage unless you pass `include=appStoreVersion`.

## Earlier status


September 13-14, 2026:

September 14 status: build **34** is processed in TestFlight and attached to the
version 1.0 draft. It includes [Sign in with Apple](apple-sign-in-release.md) and
the broader brand-discovery wording in [the copy release](brand-discovery-copy.md). The owner reports active agreements
and successful Google sign-in testing. Review contact and updated review notes
are saved in ASC. The support page is published at https://marracat.com/#/support
and its URL is saved in ASC; the privacy policy is also published and linked.
The owner confirmed the necessary brand-content permissions; ASC was verified
to have `USES_THIRD_PARTY_CONTENT` saved. The remaining checks are real-device Apple sign-in/deletion verification and
published App Privacy answers. Apple sign-in backend and native UI are deployed;
the new account screenshot is COMPLETE in ASC. Historical blockers below
describe the earlier preparation state and are superseded by this update.

The initial listing preparation below records build 31. The account release is
documented in [google-accounts-release.md](google-accounts-release.md) and
supersedes its local-only privacy and no-account description. Its release gates
and selected build are recorded there when processing finishes.

Version 1.0 has processed TestFlight build 31 attached. Its Apple-processed icon
matches `Marracat/Assets.xcassets/AppIcon.appiconset/icon-1024.png`.
The version remains **PREPARE_FOR_SUBMISSION**, not submitted or released.

## Saved in App Store Connect

- English description, keywords, promotional text, marketing URL, subtitle,
  Shopping category, copyright, and review notes from `listing-en-US.json`.
- Six real screenshots in each of APP_IPHONE_67 and APP_IPHONE_65, all COMPLETE.
  The repository copies are in `screenshots/`, in this display order:
  home, searchResultsMixed, detail, bagsSubcategories, brands, cart.
- Free download price, using the United States base territory.
- Age questionnaire from `age-rating.json`. Apple's API reports 17+ for the
  legacy App Store age field. The catalog includes alcohol, health products,
  sexual wellness, and fiction with mature themes; embedded websites allow
  navigation beyond the initial page. Infrequent/mild answers are conservative
  classifications of catalog material, not a promise that every remote page or
  future product has been reviewed. Reassess when catalog or browsing changes.
- Review notes accurately describe separate brand checkouts; combined checkout
  is not enabled in this build. Release mode remains after approval.

## Submission blockers

Apple's review-item validation still requires a review contact's first and last
name, email and international-format phone number; a privacy policy URL; a
support URL; published App Privacy answers; and a content-rights declaration.
The Account Holder also has an updated Developer Program agreement to accept.

The user has been asked for the review contact, a public support email, and the
basis for permission to display third-party catalog content. Do not invent these
answers or declare that a public product feed grants content rights.

`privacy-policy-draft.md` and `support-draft.md` are unpublished drafts. Finish
them with the confirmed contact, publish working pages, and add an accessible
privacy-policy link inside the iOS app. The account release adds an in-app privacy sheet and updates the website policy.
Its build must pass the normal full test and TestFlight shipping workflow before
being selected for review.

App Privacy must account for the embedded Shopify checkout and third-party image
and catalog hosts, not just device-local favorites and cart storage. Apple treats
webviews used for app functionality as app functionality. Confirm the checkout
providers' data practices before publishing the labels; do not choose "Data Not
Collected" simply because the Swift code has no analytics SDK.

An empty draft review submission exists. Reuse it after correcting the blockers;
the attempt to add version 1.0 failed validation and did not enter Apple's queue.
Private API responses and identifiers are retained in ignored `build/` files.

## Verification

Build 31 previously passed its full ship gate: 29 UI tests passed and two optional
checkout tests skipped. Four existing screenshot flows also passed on each of
two separate simulators in this session. All 12 images were visually reviewed
and Apple finished processing them. No native app source changed in this listing
preparation, so no additional TestFlight build was uploaded.

## Header artwork

See `assets/README.md`. Artwork is prepared locally but has not been uploaded.
Apple documents product-page headers for iOS 27 and iPadOS 27 onward, but neither
this account's current App Store Connect page nor the inspected public API
exposes the Asset Library/header upload control yet. Check again after account
agreement resolution; do not substitute an App Clip header or an app screenshot.

Sources:

- https://developer.apple.com/app-store/asset-best-practices/
- https://developer.apple.com/videos/play/wwdc2026/205/
- https://developer.apple.com/help/app-store-connect/manage-app-information/add-an-app-icon
- https://developer.apple.com/app-store/user-privacy-and-data-use/
