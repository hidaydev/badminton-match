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
 *
 * The service worker is blocked for the same reason as session-occ: once it
 * controls the tab it answers the app's fetches on its own stack, where the
 * page route never sees them, and this spec depends on rewriting their headers.
 */
test.use({ serviceWorkers: 'block' })
test('an older contract version produces the reload banner', async ({ page }) => {
  await signIn(page)

  await page.route('**/api/**', async (route) => {
    const headers = { ...route.request().headers(), 'x-api-version': '1' }
    await route.continue({ headers })
  })

  await page.goto('/')
  // DS-24 keeps the live region on the message alone (`ErrorText`), so the
  // reload action is a sibling of the alert inside the banner, not a child of
  // the role="alert" element. Look for both inside the banner.
  const banner = page.getByTestId('client-outdated')
  await expect(banner.getByRole('alert')).toHaveText(t('app.outdated'))
  await expect(banner.getByRole('button', { name: t('app.outdated.action') })).toBeVisible()
})
