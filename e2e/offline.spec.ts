import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'
import { t } from '../apps/web/src/i18n'

/**
 * The installed app opens with no network because the service worker precaches
 * the app shell (`apps/web/vite.config.ts:50-56`): the navigation fallback
 * answers an unmatched document request with the cached `index.html`, and the
 * denylist keeps `/api` out of it so an OIDC callback still reaches the server.
 *
 * Activation is observed, never waited out: `navigator.serviceWorker.ready` for
 * the worker itself, then one reload and a controller check, which is the first
 * navigation the worker is allowed to answer.
 */
async function precacheShell(page: Page) {
  await page.goto('/')
  await page.evaluate(() => navigator.serviceWorker.ready.then(() => undefined))
  await page.reload()
  await expect
    .poll(() => page.evaluate(() => navigator.serviceWorker.controller !== null))
    .toBe(true)
}

test('the app shell opens from the precache with the network offline', async ({ page, context }) => {
  await precacheShell(page)

  await context.setOffline(true)
  await page.goto('/privacy')

  // Only the precached bundle can render this: the worker answered the
  // navigation with index.html and the route came from the app, not the server.
  await expect(page.getByRole('heading', { name: t('privacy.title') })).toBeVisible()
})

test('a navigation under /api is not answered from the precache', async ({ page, context }) => {
  await precacheShell(page)

  await context.setOffline(true)
  const gotADocument = await page.goto('/api/auth/me').then(
    () => true,
    () => false,
  )

  // Without the denylist the fallback would answer this with the cached shell
  // and a 200, so an offline API call would look like a working response.
  expect(gotADocument).toBe(false)
})