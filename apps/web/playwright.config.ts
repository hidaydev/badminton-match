import { defineConfig } from 'playwright/test'
import { projects } from '../../e2e/browsers'

/**
 * T-072: browser-level regression. The browsers come from `e2e/browsers.ts` so
 * this file never guesses what "supported" means; `deps.lock` pins the build
 * and revisions they run.
 */
export default defineConfig({
  testDir: '../../e2e',
  // Every screen is compared pixel for pixel; a one-pixel drift is a real change
  // to review, not noise to tolerate.
  // Device pixels, not the default downscale to CSS pixels: resampling 2×
  // output is what made whole lines of text differ between identical runs.
  expect: { toHaveScreenshot: { maxDiffPixels: 0, scale: 'device' } },
  snapshotPathTemplate: '{testDir}/__screenshots__/{arg}-{projectName}-{platform}{ext}',
  globalSetup: '../../e2e/global-setup.ts',
  fullyParallel: true,
  forbidOnly: process.env.CI === 'true',
  retries: 0,
  reporter: process.env.CI === 'true' ? [['line']] : [['list']],
  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173',
    trace: 'retain-on-failure',
  },
  projects,
})
