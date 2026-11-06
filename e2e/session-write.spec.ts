import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

/**
 * T-030: the screens that write. The fixture session is separate from the one
 * the visual baseline pins, so a score saved here cannot drift a snapshot.
 */
test.beforeEach(async ({ page }) => {
  await signIn(page)
})

function writableSession(projectName: string): string {
  const id = state().writableByProject[projectName]
  if (id === undefined) throw new Error(`no writable session for ${projectName}`)
  return id
}

test('the host saves a score and the page re-reads it', async ({ page }) => {
  const { writableCommunitySlug } = state()
  await page.goto(
    `/c/${writableCommunitySlug}/sessions/${writableSession(test.info().project.name)}`,
  )
  // The summary dialog is the session shell; the title is a paragraph inside it.
  await page
    .getByRole('dialog', { name: 'Session summary' })
    .getByText(`E2E Writable ${test.info().project.name}`)
    .waitFor()

  // A score is entered behind the row's "+ score" toggle, and the two number
  // inputs are the only ones on the panel.
  await page.getByRole('button', { name: '+ score' }).click()
  const scores = page.locator('input[type="number"]')
  await scores.nth(0).fill('30')
  await scores.nth(1).fill('24')
  await page.getByRole('button', { name: /Save/ }).last().click()

  // The write returns a new version and the page reloads; the row only shows a
  // score once the server has it, so this is a read-after-write check.
  await expect(page.getByRole('button', { name: '30–24' })).toBeVisible()
  await expect(page.getByRole('button', { name: /^Played: / })).toBeVisible()
})
