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
 * The menu case does not assert focus return after Escape: the menu is a
 * disclosure, not a dialog, and the focus order it leaves behind is recorded as
 * an accepted risk in docs/ops/accessibility.md. The dialog case below owns the
 * focus-return assertion now that a dialog with a trigger exists.
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

  // Tab moved focus on into the page, so the trigger is not the active element
  // any more; focus it again before opening the menu from the keyboard.
  await menu.focus()
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

/**
 * QA-19: the account menu is a disclosure. This case is a real dialog opened
 * from its trigger with the keyboard only: the install sheet on the home
 * screen uses the shared `Overlay`, which moves focus into the sheet, keeps Tab
 * inside it and hands focus back to the trigger on close.
 *
 * The sheet is reachable through a user agent signal that Chromium never fires
 * under automation, so the event is dispatched the same way the a11y suite
 * does; WebKit already shows the card on its own.
 */
test('a dialog opens, traps focus and closes by keyboard alone', async ({ page }) => {
  await signIn(page)
  await page.goto(`/c/${state().communitySlug}`)
  await expect(page.getByRole('banner')).toBeVisible()

  await page.evaluate(() => {
    window.dispatchEvent(new Event('beforeinstallprompt', { cancelable: true }))
  })

  const trigger = page.getByRole('button', {
    name: new RegExp(t('home.installApp')),
  })
  await trigger.waitFor()
  await trigger.focus()
  await page.keyboard.press('Enter')

  const dialog = page.getByRole('dialog', { name: 'Install MAJADU App' })
  await expect(dialog).toBeVisible()
  // The trap focuses the sheet itself on mount, so the first Tab starts inside
  // the dialog instead of walking the page behind it.
  await expect(dialog).toBeFocused()

  // Tab and Shift+Tab both stay inside: the trap cycles at the edges, so this
  // loop can never land on the page behind the sheet.
  for (let press = 0; press < 6; press += 1) {
    await page.keyboard.press(press % 2 === 0 ? 'Tab' : 'Shift+Tab')
    const inside = await dialog.evaluate((node) => node.contains(document.activeElement))
    expect(
      inside,
      `press ${press} (${press % 2 === 0 ? 'Tab' : 'Shift+Tab'}) stays inside the dialog`,
    ).toBe(true)
  }

  await page.keyboard.press('Escape')
  await expect(dialog).toBeHidden()
  await expect(trigger).toBeFocused()
})
