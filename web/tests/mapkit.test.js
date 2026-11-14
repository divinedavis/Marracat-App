import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateKeyPair, exportPKCS8, jwtVerify } from "jose";
import { mapkitConfigured, mapkitToken } from "../server/mapkit.js";

// Address autocomplete stays off until a MapKit JS key is configured.
test("MapKit is off without its key, team and path", () => {
  assert.equal(mapkitConfigured({}), false);
  assert.equal(mapkitConfigured({ MAPKIT_KEY_ID: "K", APPLE_TEAM_ID: "T" }), false);
  assert.equal(mapkitConfigured({ MAPKIT_KEY_ID: "K", APPLE_TEAM_ID: "T", MAPKIT_PRIVATE_KEY_PATH: "/k.p8" }), true);
});

test("a MapKit token is ES256, names the key and team, is pinned to the site and short-lived", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const path = join(tmpdir(), `mapkit-test-${process.pid}.p8`);
  writeFileSync(path, await exportPKCS8(privateKey));
  const now = Date.UTC(2026, 9, 4, 12);
  const token = await mapkitToken({ MAPKIT_KEY_ID: "KEY123", APPLE_TEAM_ID: "TEAM45", MAPKIT_PRIVATE_KEY_PATH: path }, now);
  const { payload, protectedHeader } = await jwtVerify(token, publicKey, { currentDate: new Date(now) });
  assert.equal(protectedHeader.alg, "ES256");
  assert.equal(protectedHeader.kid, "KEY123");
  assert.equal(payload.iss, "TEAM45");
  assert.equal(payload.origin, "https://marracat.com");
  assert.equal(payload.exp - payload.iat, 30 * 60);
});

// 2026-11-12: every request used to read the key from disk and sign a token.
test("one MapKit token is reused for twenty minutes, then replaced", async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  const path = join(tmpdir(), `mapkit-reuse-${process.pid}.p8`);
  writeFileSync(path, await exportPKCS8(privateKey));
  const env = { MAPKIT_KEY_ID: "KEY999", APPLE_TEAM_ID: "TEAM45", MAPKIT_PRIVATE_KEY_PATH: path };
  const now = Date.UTC(2026, 10, 12, 12);
  const first = await mapkitToken(env, now);
  assert.equal(await mapkitToken(env, now + 19 * 60_000), first);
  assert.notEqual(await mapkitToken(env, now + 21 * 60_000), first);
  assert.notEqual(await mapkitToken({ ...env, MAPKIT_KEY_ID: "OTHER" }, now + 21 * 60_000 + 1000), await mapkitToken(env, now + 21 * 60_000));
});
