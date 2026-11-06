import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'

/**
 * The celebration overlay is a one-time promo on a signed-in session. It must
 * never cover the sign-in screen: a full-screen layer above the login button
 * intercepts the click and leaves a visitor stuck. This spec deliberately does
 * not use `signIn()`, which marks the promo as shown in every other test.
 */
test('the celebration never covers the sign-in screen', async ({ page }) => {
  await page.goto('/')

  const signIn = page.getByRole('button', { name: t('login.action') })
  await expect(signIn).toBeVisible()
  await expect(
    page.getByRole('dialog', { name: 'Championship celebration' }),
  ).toHaveCount(0)

  // Clickable, not merely present: an overlay would swallow the click.
  await signIn.click()
  await expect(page.getByRole('button', { name: t('login.action') })).toHaveCount(0)
})
