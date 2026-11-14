import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests/browser",
  use: {
    baseURL: process.env.TEST_BASE_URL || "http://127.0.0.1:3107",
    channel: "chrome",
    headless: true,
    // Journeys stub the site's own requests with page.route, which a service
    // worker's fetches would slip past; tests/browser/offline.spec.js turns
    // it back on for itself.
    serviceWorkers: "block",
  },
  workers: 1,
  reporter: "list",
});
