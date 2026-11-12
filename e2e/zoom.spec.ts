import { expect, test } from 'playwright/test'
import { state } from './global-setup'
import { signIn } from './session'

/**
 * QA-19: WCAG 1.4.10 on the desktop side. `reflow.spec.ts` already tests a
 * 320 CSS pixel phone, which is stricter than 200 percent zoom on that screen.
 * The desktop case is different: 200 percent zoom on a 1440 pixel window leaves
 * 720 CSS pixels of layout, which crosses the `md:`/`lg:` breakpoints the phone
 * never reaches.
 *
 * Playwright has no browser-zoom API, so the zoom is expressed the way the
 * browser expresses it: halve the CSS viewport. 1440 x 900 at 200 percent is
 * 720 x 450 of layout, and the assertion is the document, not a container — a
 * screen that scrolls sideways hides content from a keyboard or a magnifier
 * even when the markup looks fine.
 *
 * The case runs once, on the desktop project; the phone projects skip it.
 */

const screens = [
  { name: 'community', path: () => `/c/${state().communitySlug}` },
  { name: 'sessions', path: () => `/c/${state().communitySlug}/sessions` },
  { name: 'rankings', path: () => `/c/${state().communitySlug}/rankings` },
  { name: 'settings', path: () => `/c/${state().communitySlug}/settings` },
]

for (const screen of screens) {
  test(`${screen.name} at 200 percent zoom has no horizontal scroll`, async ({
    page,
  }) => {
    test.skip(
      test.info().project.name !== 'desktop',
      'the 200 percent case is the desktop project',
    )
    await page.setViewportSize({ width: 720, height: 450 })
    await signIn(page)
    await page.goto(screen.path())
    await expect(page.getByRole('banner')).toBeVisible()

    const overflow = await page.evaluate(
      () =>
        document.documentElement.scrollWidth -
        document.documentElement.clientWidth,
    )
    expect(
      overflow,
      `${screen.name} scrolls sideways by ${overflow}px at 200 percent zoom`,
    ).toBeLessThanOrEqual(1)
  })
}
