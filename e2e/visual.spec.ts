import { expect, test } from 'playwright/test'
import { signIn } from './session'
import { state } from './global-setup'
import { visualRoutes } from './visual.routes'

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

for (const route of visualRoutes) {
  test(`${route.name} matches the baseline`, async ({ page }) => {
    await page.goto(route.path(state()))
    await page.waitForLoadState('networkidle')
    // Fonts are served from the repo and still have to arrive before the glyphs
    // settle; a screenshot taken during the swap diffs every word on the page.
    await page.addStyleTag({
      content:
        '*, *::before, *::after { animation: none !important; transition: none !important; }',
    })
    await page.evaluate(async () => {
      await document.fonts.ready
    })
    await expect(page).toHaveScreenshot(`${route.name}.png`, { fullPage: true })
  })
}
