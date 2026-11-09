import { expect, test } from 'playwright/test'
import { signIn } from './session'
import { state } from './global-setup'
import { visualRoutes } from './visual.routes'

/**
 * Pixel baselines are recorded per platform, in `__screenshots__/{platform}/`,
 * because text rasterisation differs between macOS and Linux and production is
 * Linux. Both sets are committed: the macOS one is what a developer records and
 * reviews locally, and the Linux one is recorded on a Linux machine, reviewed
 * and committed. CI only compares (D-8, D-13).
 *
 * A platform with no baseline fails here rather than skipping: recording is an
 * explicit `./task e2e --update-snapshots` whose diff lands in the pull request.
 * Snapshot tests carry the `@visual` tag so CI can exclude only them on main and
 * pull requests while the Linux set is absent; tags and `release/*` branches
 * never take that path, so a missing baseline fails there.
 */

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

for (const route of visualRoutes) {
  test(`${route.name} matches the baseline @visual`, async ({ page }) => {
    // The session list prints a date-filter chip and the export poster prints
    // the day it was opened; both read the browser clock. Pin it so a baseline
    // recorded on one day is still valid the next.
    await page.clock.setFixedTime(new Date('2026-11-04T12:00:00Z'))
    await page.goto(route.path(state()))
    // Readiness is data, not silence: `networkidle` never settles on a screen
    // that holds a WebSocket open, and a screenshot of a loading skeleton is a
    // baseline nobody meant to approve.
    // `visible`: the same words can sit in a hidden <option> of a picker, and
    // a readiness check that matches one is not waiting for the screen.
    await page.locator(route.ready(state())).filter({ visible: true }).first().waitFor()
    // Fonts are served from the repo and still have to arrive before the glyphs
    // settle; a screenshot taken during the swap diffs every word on the page.
    await page.addStyleTag({
      content:
        '*, *::before, *::after { animation: none !important; transition: none !important; }',
    })
    await page.evaluate(async () => {
      await document.fonts.ready
    })
    await expect(page).toHaveScreenshot(`${route.name}.png`, {
      fullPage: true,
      // Routes that print an empty date filter get it masked: WebKit fills an
      // empty `<input type="date">` with today's date and `setFixedTime` does
      // not reach that native control. Screens that hold a pinned date (the
      // export poster) keep their field visible.
      mask: route.maskDateFilter ? [page.locator('input[type="date"]')] : [],
      maskColor: '#1c212b',
    })
  })
}