import { test } from "node:test";
import assert from "node:assert/strict";
import express from "express";
import { iosAppRoutes, IOS_APP_URL, IOS_APP_ID } from "../server/ios-app.js";

const listing = { resultCount: 1, results: [{ version: "1.0", minimumOsVersion: "17.0" }] };
const removed = { resultCount: 0, results: [] };

function serve(fetcher, clock = { t: 1_000_000 }) {
  const app = express();
  const routes = iosAppRoutes(app, { fetcher, now: () => clock.t });
  return { app, routes, clock };
}

async function get(app) {
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  try {
    const { port } = server.address();
    const r = await fetch(`http://127.0.0.1:${port}/api/ios-app`);
    return { status: r.status, body: await r.json() };
  } finally {
    server.close();
  }
}

test("a live listing gets the banner and the real App Store link", async () => {
  const { app } = serve(async () => ({ ok: true, json: async () => listing }));
  const { status, body } = await get(app);
  assert.equal(status, 200);
  assert.equal(body.live, true);
  assert.equal(body.url, IOS_APP_URL);
  assert.ok(body.url.includes(IOS_APP_ID));
  assert.equal(body.version, "1.0");
});

/// The state this was written in: approved, but removed from sale, so the
/// store page 404s. The banner must stay off rather than send anyone there.
test("an app removed from sale reports not live", async () => {
  const { app } = serve(async () => ({ ok: true, json: async () => removed }));
  const { body } = await get(app);
  assert.equal(body.live, false);
});

test("Apple being unreachable doesn't declare a live app dead", async () => {
  let calls = 0;
  const clock = { t: 1_000_000 };
  const { app, routes } = serve(async () => {
    calls += 1;
    if (calls === 1) return { ok: true, json: async () => listing };
    throw new Error("network");
  }, clock);
  assert.equal((await get(app)).body.live, true);
  clock.t += 2 * 60 * 60 * 1000; // stale, so the next call refreshes
  await routes.check(); // the refresh fails
  assert.equal((await get(app)).body.live, true, "kept the last known answer");
});

test("the answer is cached instead of calling Apple on every view", async () => {
  let calls = 0;
  const { app } = serve(async () => {
    calls += 1;
    return { ok: true, json: async () => listing };
  });
  await get(app);
  await get(app);
  await get(app);
  assert.equal(calls, 1);
});

/// Availability saved in App Store Connect can take hours to reach the store.
/// The override covers that gap without waiting on Apple.
test("the override shows the banner before Apple's lookup catches up", async () => {
  const app = express();
  iosAppRoutes(app, {
    fetcher: async () => ({ ok: true, json: async () => removed }),
    env: { IOS_APP_FORCE_LIVE: "1" },
  });
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  try {
    const { port } = server.address();
    const body = await (await fetch(`http://127.0.0.1:${port}/api/ios-app`)).json();
    assert.equal(body.live, true);
    assert.equal(body.url, IOS_APP_URL);
  } finally {
    server.close();
  }
});

/// Apple returns 200 with zero rows to a caller that doesn't look like a
/// browser, which read as "the app isn't on the store" for a live app.
test("the lookup identifies itself as a browser", async () => {
  let sent = null;
  const app = express();
  iosAppRoutes(app, {
    fetcher: async (_url, opts) => {
      sent = opts?.headers ?? null;
      return { ok: true, json: async () => listing };
    },
  });
  const server = app.listen(0, "127.0.0.1"); await new Promise((r) => server.once("listening", r));
  try {
    const { port } = server.address();
    await fetch(`http://127.0.0.1:${port}/api/ios-app`);
  } finally {
    server.close();
  }
  assert.match(sent?.["User-Agent"] ?? "", /Mozilla\/5\.0/);
});
