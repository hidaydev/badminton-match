import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

/**
 * The overlay sheet contract on real screens. The unit test in
 * `components/Overlay.test.tsx` mocks the DOM; these assertions run the two
 * phone engines the app ships to, against the seeded API.
 *
 * Two surfaces, each for what it alone can show:
 *
 * - The classic tournament's score sheet has a footer and opens from a page
 *   long enough to scroll, so the body lock has a real offset to restore.
 * - The session page's share-link sheet is a second sheet stacked over the
 *   summary dialog, so Escape proves it closes only the top one.
 */

const SCORE_SHEET = 'Enter Score'
/** The only group match the fixture scores this way; the label includes it. */
const SCORED_MATCH = /27–29/

async function openScorePage(page: Page) {
  const { communitySlug, tournamentId } = state()
  await page.goto(`/c/${communitySlug}/tournaments/${tournamentId}`)
  const match = page.getByRole('button', { name: SCORED_MATCH })
  await match.scrollIntoViewIfNeeded()
  const sheet = page.getByRole('dialog', { name: SCORE_SHEET })
  return { match, sheet }
}

async function openScoreSheet(page: Page) {
  const { match, sheet } = await openScorePage(page)
  await match.click()
  await expect(sheet).toBeVisible()
  return { match, sheet }
}

async function openShareSheet(page: Page) {
  const { communitySlug, sessionId } = state()
  await page.goto(`/c/${communitySlug}/sessions/${sessionId}`)

  const summary = page.getByRole('dialog', { name: t('summary.title') })
  await expect(summary).toBeVisible()
  const trigger = summary.getByRole('button', { name: t('session.share') })
  // WebKit does not focus a button on a pointer tap, so a keyboard open is the
  // portable way to have a focused opener for the trap to hand focus back to.
  await trigger.focus()
  await page.keyboard.press('Enter')

  const share = page.getByRole('dialog', { name: t('session.share') })
  await expect(share).toBeVisible()
  return { summary, trigger, share }
}

test('the page does not scroll behind the sheet and the offset is restored', async ({ page }) => {
  await signIn(page)
  const { match, sheet } = await openScorePage(page)

  // Scrolling the target into view can leave it at the very edge; a further
  // nudge keeps it clickable and makes the saved offset non-zero.
  await expect(match).toBeInViewport()
  await page.evaluate(() => window.scrollBy(0, 120))
  await expect(match).toBeInViewport()
  const scrolled = await page.evaluate(() => window.scrollY)
  expect(scrolled).toBeGreaterThan(0)

  await match.click()
  await expect(sheet).toBeVisible()

  // QA-28: the assertion is the observable behaviour, not the inline styles the
  // current implementation happens to use. A refactor to `inert`, `overflow:
  // clip` or a scroll container must keep this green as long as the page behind
  // the sheet cannot move.
  const locked = await page.evaluate(() => window.scrollY)
  await page.evaluate(() => window.scrollBy(0, 200))
  expect(await page.evaluate(() => window.scrollY)).toBe(locked)

  await sheet.getByRole('button', { name: 'Cancel' }).click()
  await expect(sheet).toBeHidden()

  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(scrolled)
})

test('Escape closes only the top sheet and returns focus to its trigger', async ({ page }) => {
  await signIn(page)
  const { summary, trigger, share } = await openShareSheet(page)

  await page.keyboard.press('Escape')
  await expect(share).toBeHidden()
  // The summary is the screen underneath, not another sheet: it stays open.
  await expect(summary).toBeVisible()
  await expect(trigger).toBeFocused()
})

test('a scrim tap closes the sheet but a drag that starts inside does not', async ({ page }) => {
  await signIn(page)
  const { summary, share } = await openShareSheet(page)

  const viewport = page.viewportSize()
  if (viewport === null) throw new Error('the project has no viewport')
  const centre = viewport.width / 2
  // The sheet is bottom-aligned and short, so the top strip is scrim and the
  // bottom strip is inside it. Fixed points keep the assertion independent of
  // how many rows the share panel has loaded.
  const scrimY = 8
  const insideY = viewport.height - 40

  // A press that starts inside and ends on the scrim still fires a click on the
  // scrim; only a gesture that began there may close.
  await page.mouse.move(centre, insideY)
  await page.mouse.down()
  await page.mouse.move(centre, scrimY, { steps: 5 })
  await page.mouse.up()
  await expect(share).toBeVisible()

  await page.mouse.click(centre, scrimY)
  await expect(share).toBeHidden()
  await expect(summary).toBeVisible()
})

test('the footer action is reachable without scrolling the page behind', async ({ page }) => {
  await signIn(page)
  const { sheet } = await openScoreSheet(page)

  const cancel = sheet.getByRole('button', { name: 'Cancel' })
  await expect(cancel).toBeInViewport()
  await expect(cancel).toBeEnabled()
  await cancel.click()
  await expect(sheet).toBeHidden()
})

test('both sheets open and close from the keyboard alone', async ({ page }) => {
  // QA-19: a pointer is not an accessibility path. Open the score sheet from a
  // focused trigger, close it with Escape, then do the same for the share sheet
  // stacked over the summary.
  await signIn(page)
  const { match, sheet } = await openScorePage(page)
  await match.focus()
  await page.keyboard.press('Enter')
  await expect(sheet).toBeVisible()
  await page.keyboard.press('Escape')
  await expect(sheet).toBeHidden()

  const { share } = await openShareSheet(page)
  await page.keyboard.press('Escape')
  await expect(share).toBeHidden()
})