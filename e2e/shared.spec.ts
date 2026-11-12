import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'

/**
 * The spectator path: no cookie, no community, no edit controls. Everything here
 * comes from the code in the URL, and the body is the in-app session screen in
 * read-only mode.
 */
test('a share link opens without a session and shows the games', async ({ page }) => {
  const { shareCode, shareTitle } = state()

  await page.goto(`/s/${shareCode}`)

  await expect(page.getByText(shareTitle)).toBeVisible()
  await expect(page.getByRole('tab', { name: t('summary.tab.schedule') })).toBeVisible()
  await expect(page.getByRole('tab', { name: t('summary.tab.standings') })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Played: Ani & Budi vs Candra & Dewi' })).toBeDisabled()
  await expect(page.getByText('30–24')).toBeVisible()

  // A guest taps a name to highlight that player's games; every edit control
  // the in-app header carries stays out of the render.
  await page.getByRole('button', { name: /^Ani/ }).click()
  await page.getByRole('tab', { name: t('summary.tab.standings') }).click()
  for (const label of [
    t('summary.finish'),
    t('summary.reopen'),
    t('summary.actions'),
    t('summary.delete'),
    t('session.share'),
  ]) {
    await expect(page.getByRole('button', { name: label })).toHaveCount(0)
  }

  await page.goto('/s/not-a-real-code')
  await expect(page.getByText(t('shared.error.missing'))).toBeVisible()
})
