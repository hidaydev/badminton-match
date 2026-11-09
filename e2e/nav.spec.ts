import { expect, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

test('the account menu opens, navigates and closes @visual', async ({ page }) => {
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
/**
 * The account menu advertises `role="menu"`, so it has to answer the keyboard
 * the way a menu does: focus lands inside on open, the arrows move, Home/End
 * jump, and Escape closes it and returns focus to the trigger.
 */
test('the account menu follows the menu keyboard pattern', async ({ page }) => {
  await signIn(page)
  await page.goto(`/c/${state().communitySlug}`)

  const trigger = page.getByRole('button', { name: t('shell.account') })
  await trigger.focus()
  await page.keyboard.press('Enter')

  const menu = page.getByRole('menu')
  await expect(menu).toBeVisible()
  // Both roles count as menu items, and only the rows the user can see take
  // focus: the community switch is hidden where the header picker shows it.
  const entries = menu.locator('[role="menuitem"]:visible, [role="menuitemradio"]:visible')
  await expect(entries.first()).toBeFocused()

  await page.keyboard.press('ArrowDown')
  await expect(entries.nth(1)).toBeFocused()

  await page.keyboard.press('End')
  await expect(entries.last()).toBeFocused()

  await page.keyboard.press('Escape')
  await expect(menu).toBeHidden()
  await expect(trigger).toBeFocused()
})
