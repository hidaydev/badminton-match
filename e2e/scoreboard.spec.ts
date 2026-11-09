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

/**
 * The score face is a real `<button>` whose accessible name starts with the
 * team name. The fixture never renames a side, so the red half is still "RED";
 * matching on the name keeps the locator off the blue half even after a swap.
 */
function redSide(page: Page) {
  return page.getByRole('button', { name: /^RED, \d+, tap to score$/ })
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
  // The score reaches storage in an effect, so wait for the persisted value
  // before going offline; otherwise the reload can race the write.
  await expect
    .poll(() => page.evaluate(() => localStorage.getItem('score-red')))
    .toBe('1')

  await context.setOffline(true)
  await page.reload()

  // Only the precached shell can render this: the worker answered the
  // navigation with index.html, and the score came from localStorage.
  await expect
    .poll(() => page.evaluate(() => navigator.serviceWorker.controller !== null))
    .toBe(true)
  await expect(page.getByText('Offline, scores stay on this device')).toBeVisible()
  await expect(redSide(page)).toContainText('1')
  await redSide(page).click()
  await expect(redSide(page)).toContainText('2')
})

test('a second window is read-only while the first keeps score', async ({ context }) => {
  await context.addInitScript(() => {
    localStorage.setItem('pwa-install-shown', new Date().toDateString())
  })

  const first = await context.newPage()
  await precacheShell(first)

  // Wait for the first document to hold the writer lock; opening the second
  // page earlier would race the grant and make this test flaky.
  await expect
    .poll(() =>
      first.evaluate(async () => {
        const { held } = await navigator.locks.query()
        return (held ?? []).some(lock => lock.name === 'majadu-score-writer')
      }),
    )
    .toBe(true)

  const second = await context.newPage()
  await second.goto(scoreboardURL)

  await expect(second.getByText('Another window is keeping score')).toBeVisible()
  await expect(redSide(second)).toBeDisabled()
})
