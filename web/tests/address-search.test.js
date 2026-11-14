import { test } from "node:test";
import assert from "node:assert/strict";
import { placeToAddress } from "../src/addressSearch.js";

// A picked Apple Maps suggestion fills street, city, state and ZIP.
test("a MapKit place becomes the form's address fields", () => {
  assert.deepEqual(
    placeToAddress({ subThoroughfare: "228", thoroughfare: "Grant St", locality: "Brooklyn",
      administrativeArea: "New York", administrativeAreaCode: "NY", postCode: "11205", countryCode: "US" }),
    { street: "228 Grant St", city: "Brooklyn", region: "NY", postalCode: "11205", country: "US" });
});

test("fullThoroughfare wins, missing parts stay blank, no place is null", () => {
  assert.equal(placeToAddress({ fullThoroughfare: "1600 Pennsylvania Ave NW", thoroughfare: "x" }).street, "1600 Pennsylvania Ave NW");
  assert.deepEqual(placeToAddress({ locality: "Newark", administrativeArea: "NJ" }),
    { street: "", city: "Newark", region: "NJ", postalCode: "", country: "" });
  assert.equal(placeToAddress(null), null);
});
