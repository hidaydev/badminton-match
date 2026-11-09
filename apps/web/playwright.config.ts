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
  // One directory per platform: the Linux set is recorded on the runner that
  // serves the app, the macOS set is what a developer reviews locally, and both
  // are committed (D-8, D-13).
  snapshotPathTemplate: '{testDir}/__screenshots__/{platform}/{arg}-{projectName}{ext}',
  globalSetup: '../../e2e/global-setup.ts',
  fullyParallel: true,
  forbidOnly: process.env.CI === 'true',
  retries: 0,
  // A machine-readable report as well, so a flaky test can be named from the
  // artifact instead of from a scrolling log (QA-13), and an HTML report for
  // human triage (QA-11). Artifacts land under `test-results/` next to the
  // config, which is the directory CI uploads on failure.
  outputDir: 'test-results',
  // The HTML report cannot live inside `outputDir`: Playwright empties that
  // folder at the start of a run and refuses a reporter folder it would delete.
  reporter: process.env.CI === 'true'
    ? [['line'], ['json', { outputFile: 'test-results/playwright.json' }],
       ['html', { outputFolder: 'playwright-report', open: 'never' }]]
    : [['list'], ['json', { outputFile: 'test-results/playwright.json' }]],
  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173',
    // QA-11: a failure must leave the frame, the video and the trace behind,
    // not only a console line. `retain-on-failure` keeps a passing run cheap.
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects,
})
