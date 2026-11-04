import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { signIn } from './session'

/**
 * A tab left open across a deploy keeps its bundle. The API answers 410 and the
 * shell must say so instead of failing one request at a time.
 *
 * The contract generation is what an older bundle would send, so rewriting the
 * header is the part of "old bundle, new API" that this repository can produce
 * today; a bundle from the previous release needs a release to exist first.
 */
test('an older contract version produces the reload banner', async ({ page }) => {
  await signIn(page)

  await page.route('**/api/**', async (route) => {
    const headers = { ...route.request().headers(), 'x-api-version': '1' }
    await route.continue({ headers })
  })

  await page.goto('/')
  const banner = page.getByRole('alert').filter({ hasText: t('app.outdated') })
  await expect(banner).toBeVisible()
  await expect(banner.getByRole('button', { name: t('app.outdated.action') })).toBeVisible()
})
