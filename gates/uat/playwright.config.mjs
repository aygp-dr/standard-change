// The fastest configuration that is still a browser: one headless Chromium,
// one worker, one spec, no retries, no video. Everything a person would see
// is asserted from the DOM; the pipeline facts (which app, which build) are
// read from the response headers the router already sets.
//
// ROUTER_URL is the estate under test -- a worktree block locally, the staging
// front in activation. PLAYWRIGHT_CHROME points at a system browser where
// Playwright ships none (FreeBSD: /usr/local/bin/chrome).
import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: ".",
  testMatch: "journey.spec.mjs",
  workers: 1,
  retries: 0,
  timeout: 15_000,
  reporter: [["list"]],
  use: {
    baseURL: process.env.ROUTER_URL || "http://127.0.0.1:9000",
    headless: true,
    launchOptions: process.env.PLAYWRIGHT_CHROME
      ? { executablePath: process.env.PLAYWRIGHT_CHROME }
      : {},
  },
});
