import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

test('the account menu opens, navigates and closes', async ({ page }) => {
  await signIn(page)
  // Inside a community the menu has more than one link to navigate between.
  await page.goto(`/c/${state().communitySlug}`)

  const menu = page.getByRole('button', { name: t('shell.account') })
  const navigation = page.getByRole('menu')
  await expect(navigation).toBeHidden()

  await menu.click()
  await expect(navigation).toBeVisible()
  await expect(menu).toHaveAttribute('aria-expanded', 'true')
  // Same per-platform rule as `visual.spec.ts`: the baseline lives under
  // `__screenshots__/{platform}/` and every run compares it.
  await expect(page).toHaveScreenshot('nav-open.png')

  await navigation.getByRole('menuitem', { name: t('nav.settings') }).click()
  await expect(page).toHaveURL(new RegExp(`/c/${state().communitySlug}/settings$`))
  await expect(navigation).toBeHidden()
})