import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'

/**
 * The spectator path: no cookie, no community, no controls. Everything here
 * comes from the code in the URL.
 */
test('a share link opens without a session and shows the games', async ({ page }) => {
  const { shareCode, shareTitle } = state()

  await page.goto(`/s/${shareCode}`)

  await expect(page.getByRole('heading', { name: shareTitle })).toBeVisible()
  await expect(page.getByText('Ani & Budi')).toBeVisible()
  await expect(page.getByText('30–24')).toBeVisible()
  await expect(page.getByRole('button')).toHaveCount(0)

  await page.goto('/s/not-a-real-code')
  await expect(page.getByText(t('shared.error.missing'))).toBeVisible()
})
