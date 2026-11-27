import { expect, test } from 'playwright/test'
import { state } from './global-setup'
import { signIn } from './session'

/**
 * T-030: the screens that write. The fixture session is separate from the one
 * the visual baseline pins, so a score saved here cannot drift a snapshot. It is
 * also per repeat: `--repeat-each` runs this test beside a copy of itself, and
 * two copies saving one session would race on its version.
 */
test.beforeEach(async ({ page }) => {
  await signIn(page)
})

test('the host saves a score and the page re-reads it', async ({ page }) => {
  const { writableCommunitySlug } = state()
  const info = test.info()
  const session = state().writableByProject[info.project.name]?.[info.repeatEachIndex]
  if (session === undefined) {
    throw new Error(`no writable session for ${info.project.name} r${info.repeatEachIndex + 1}`)
  }
  const scoreA = 30
  const scoreB = 24

  await page.goto(`/c/${writableCommunitySlug}/sessions/${session.id}`)
  // MAJ-04: the session sheet is the page, so it is a named region, not a dialog.
  await page
    .getByRole('region', { name: 'Session summary' })
    .getByText(session.title)
    .waitFor()

  // A score is entered behind the row's "+ score" toggle. The two number inputs
  // are the only ones on the panel.
  await page.getByRole('button', { name: '+ score' }).click()
  const scores = page.locator('input[type="number"]')
  await scores.nth(0).fill(String(scoreA))
  await scores.nth(1).fill(String(scoreB))
  await page.getByRole('button', { name: /Save/ }).last().click()

  // The write returns a new version and the page reloads; the row only shows a
  // score once the server has it, so this is a read-after-write check.
  await expect(page.getByRole('button', { name: `${scoreA}–${scoreB}` })).toBeVisible()
  await expect(page.getByRole('button', { name: /^Played: / })).toBeVisible()
})
