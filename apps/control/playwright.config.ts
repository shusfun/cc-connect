import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './e2e', testMatch: '**/*.spec.ts', workers: 1, timeout: 30000,
  outputDir: '/tmp/remodex-control-browser-results',
  use: { baseURL: 'https://127.0.0.1:19831', ignoreHTTPSErrors: true, browserName: 'chromium', channel: process.env.REMODEX_TEST_BROWSER_CHANNEL || undefined, screenshot: 'only-on-failure' },
  webServer: { command: 'node e2e/server.cjs', url: 'https://127.0.0.1:19831/__test/health', ignoreHTTPSErrors: true, reuseExistingServer: false, timeout: 20000 },
});
