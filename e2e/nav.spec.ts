import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

test('the phone menu opens, navigates and closes', async ({ page }) => {
  await signIn(page)
  // Inside a community the menu has more than one link to navigate between.
  await page.goto(`/c/${state().communitySlug}`)

  const menu = page.getByRole('button', { name: t('nav.menu') })
  const navigation = page.getByRole('navigation', { name: t('nav.group.main') })
  await expect(navigation).toBeHidden()

  await menu.click()
  await expect(navigation).toBeVisible()
  await expect(page.getByRole('button', { name: t('nav.menu.close') })).toHaveAttribute(
    'aria-expanded',
    'true',
  )
  // Same per-platform rule as `visual.spec.ts`; CI runs the navigation itself.
  if (process.env.E2E_VISUAL !== '0') {
    await expect(page).toHaveScreenshot('nav-open.png')
  }

  await navigation.getByRole('link', { name: t('nav.sessions') }).first().click()
  await expect(page).toHaveURL(new RegExp(`/c/${state().communitySlug}/sessions$`))
  await expect(page.getByRole('button', { name: t('nav.menu') })).toHaveAttribute(
    'aria-expanded',
    'false',
  )
  await expect(navigation).toBeHidden()
})
