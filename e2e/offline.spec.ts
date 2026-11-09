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

/**
 * PWA-23: the social export draws on a canvas with both decorative faces. If a
 * face is missing the browser silently substitutes a system font, so compare
 * pixels and the font-loading verdict, not the text.
 */
async function exportFonts(page: Page) {
  return page.evaluate(async () => {
    await document.fonts.load('72px Edosz')
    await document.fonts.load('32px "Road Rage"')
    const canvas = document.createElement('canvas')
    canvas.width = 240
    canvas.height = 100
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new Error('canvas is unavailable')
    ctx.fillStyle = '#fff'
    ctx.fillRect(0, 0, 240, 100)
    ctx.fillStyle = '#000'
    ctx.font = '72px Edosz'
    ctx.fillText('2026', 0, 60)
    ctx.font = '32px "Road Rage"'
    ctx.fillText('RC', 4, 95)
    return {
      signature: canvas.toDataURL(),
      edosz: document.fonts.check('72px Edosz'),
      roadRage: document.fonts.check('32px "Road Rage"'),
    }
  })
}

test('the export fonts render the same offline', async ({ page, context }) => {
  await precacheShell(page)

  const online = await exportFonts(page)
  expect(online.edosz).toBe(true)
  expect(online.roadRage).toBe(true)

  await context.setOffline(true)
  await page.reload()

  const offline = await exportFonts(page)
  expect(offline.edosz).toBe(true)
  expect(offline.roadRage).toBe(true)
  expect(offline.signature).toBe(online.signature)
})