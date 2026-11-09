import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'

/**
 * PWA-03: the scoreboard is the build used in the hall, and every other browser
 * test drives the web app. This spec loads the built scoreboard from its own
 * preview, scores a point, then goes offline and proves the service worker
 * answered the reload from the precache and the board still keeps score.
 *
 * No screenshot here: the visual gate is `visual.spec.ts`, so this spec runs
 * even before the Linux baseline exists.
 */
const scoreboardURL =
  process.env.E2E_SCOREBOARD_BASE_URL ?? 'http://127.0.0.1:4173'

/** The red half is the first side: it is the left panel until a swap. */
function redSide(page: Page) {
  return page.locator('[role="button"]').filter({ hasText: 'tap to score' }).first()
}

async function precacheShell(page: Page) {
  await page.goto(scoreboardURL)
  await page.evaluate(() => navigator.serviceWorker.ready.then(() => undefined))
  await page.reload()
  await expect
    .poll(() => page.evaluate(() => navigator.serviceWorker.controller !== null))
    .toBe(true)
}

test('the scoreboard scores offline from the precache', async ({ page, context }) => {
  // The install sheet is not what this test covers; suppressing it keeps the
  // scoring surface free of an overlay on the iOS engine.
  await page.addInitScript(() => {
    localStorage.setItem('pwa-install-shown', new Date().toDateString())
  })

  await precacheShell(page)

  await expect(redSide(page)).toContainText('0')
  await redSide(page).click()
  await expect(redSide(page)).toContainText('1')

  await context.setOffline(true)
  await page.reload()

  // Only the precached shell can render this: the worker answered the
  // navigation with index.html, and the score came from localStorage.
  await expect
    .poll(() => page.evaluate(() => navigator.serviceWorker.controller !== null))
    .toBe(true)
  await expect(redSide(page)).toContainText('1')
  await redSide(page).click()
  await expect(redSide(page)).toContainText('2')
})
