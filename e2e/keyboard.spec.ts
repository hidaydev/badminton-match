import { expect, test } from 'playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { t } from '../apps/web/src/i18n'
import { signIn } from './session'
import { state } from './global-setup'

/**
 * ISO-15: the axe suite proves the rendered state is clean, not that the
 * controls can be operated without a pointer. This spec opens the account menu
 * and leaves it with the keyboard only: no `click` on the menu or its items.
 *
 * It does not assert focus return after Escape. The menu is a disclosure, not a
 * dialog, and the focus order it leaves behind is recorded as an accepted risk
 * in docs/ops/accessibility.md until a dialog exists to return focus to.
 */
test('the account menu is operable by keyboard alone', async ({ page }) => {
  await signIn(page)
  await page.goto(`/c/${state().communitySlug}`)

  const menu = page.getByRole('button', { name: t('shell.account') })
  const navigation = page.getByRole('menu')

  await menu.focus()
  await page.keyboard.press('Enter')
  await expect(navigation).toBeVisible()

  // The open menu is a state axe never saw in the signed-in route sweep.
  const violations = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .analyze()
  expect(
    violations.violations.map(
      (violation) =>
        `${violation.id} (${violation.impact}): ${violation.nodes
          .map((node) => node.target.join(' '))
          .join(', ')}`,
    ),
  ).toEqual([])

  await page.keyboard.press('Escape')
  await expect(navigation).toBeHidden()

  // Opening the menu puts focus on its first item, so a keyboard user is
  // already inside the disclosure without a Tab press; and Tab leaves the menu
  // and closes it, so the next Shift+Tab is not trapped behind a popup the user
  // has left. The pattern is the component's, so the spec asserts it.
  await page.keyboard.press('Enter')
  await expect(navigation).toBeVisible()
  await expect(navigation.locator(':focus')).toHaveCount(1)
  await page.keyboard.press('Tab')
  await expect(navigation).toBeHidden()

  await page.keyboard.press('Enter')
  await expect(navigation).toBeVisible()
  const settings = navigation.getByRole('menuitem', { name: t('nav.settings') })
  await settings.focus()
  await page.keyboard.press('Enter')
  await expect(page).toHaveURL(
    new RegExp(`/c/${state().communitySlug}/settings$`),
  )
  await expect(navigation).toBeHidden()
})
