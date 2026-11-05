import { expect, test } from 'playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { signIn } from './session'
import { state } from './global-setup'
import { a11yRoutes } from './visual.routes'

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

for (const route of a11yRoutes) {
  test(`${route.name} has no accessibility violations`, async ({ page }) => {
    await page.goto(route.path(state()))
    await page.waitForLoadState('networkidle')

    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze()

    const summary = results.violations.map(
      (violation) =>
        `${violation.id} (${violation.impact}): ${violation.nodes
          .map((node) => node.target.join(' '))
          .join(', ')}`,
    )
    expect(summary).toEqual([])
  })
}
