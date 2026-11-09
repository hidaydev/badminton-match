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
    // Readiness is data, not silence: `networkidle` never settles on a screen
    // that holds a WebSocket open, and it hides a failed read behind a timeout.
    // `visible`: the same words can sit in a hidden <option> of a picker, and
    // a readiness check that matches one is not waiting for the screen.
    await page.locator(route.ready(state())).filter({ visible: true }).first().waitFor()

    const wcag = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze()
    // `heading-order` is tagged best-practice, so it cannot ride along with the
    // WCAG tag filter. `.options()` replaces the filter rather than adding to
    // it, so ask for the rule by id in a second pass: a filtered run would
    // silently drop it again.
    const headings = await new AxeBuilder({ page })
      .withRules(['heading-order'])
      .analyze()

    const summary = [...wcag.violations, ...headings.violations].map(
      (violation) =>
        `${violation.id} (${violation.impact}): ${violation.nodes
          .map((node) => node.target.join(' '))
          .join(', ')}`,
    )
    expect(summary).toEqual([])
  })
}