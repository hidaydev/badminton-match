import { expect, test } from 'playwright/test'
import { signIn } from './session'
import { state } from './global-setup'
import { visualRoutes } from './visual.routes'

/**
 * Pixel baselines are recorded per platform (`snapshotPathTemplate` carries
 * `{platform}`) because text rasterisation differs between macOS and Linux.
 * CI has no Linux baseline yet, so it sets `E2E_VISUAL=0` and keeps every other
 * assertion running; `./task e2e --update-snapshots` records the missing set.
 */
const visualBaselines = process.env.E2E_VISUAL !== '0'
test.skip(!visualBaselines, 'pixel baselines are recorded per platform')

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

for (const route of visualRoutes) {
  test(`${route.name} matches the baseline`, async ({ page }) => {
    // The session list prints a date-filter chip and the export poster prints
    // the day it was opened; both read the browser clock. Pin it so a baseline
    // recorded on one day is still valid the next.
    await page.clock.setFixedTime(new Date('2026-11-04T12:00:00Z'))
    await page.goto(route.path(state()))
    await page.waitForLoadState('networkidle')
    // Fonts are served from the repo and still have to arrive before the glyphs
    // settle; a screenshot taken during the swap diffs every word on the page.
    await page.addStyleTag({
      content:
        '*, *::before, *::after { animation: none !important; transition: none !important; }',
    })
    await page.evaluate(async () => {
      await document.fonts.ready
    })
    await expect(page).toHaveScreenshot(`${route.name}.png`, { fullPage: true })
  })
}
