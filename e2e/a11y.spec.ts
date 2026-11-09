import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { t } from '../apps/web/src/i18n'
import { signIn } from './session'
import { state } from './global-setup'
import { a11yRoutes } from './visual.routes'
import type { E2eState } from './visual.routes'

/**
 * A surface that only exists after a click: a sheet, a menu, an install
 * prompt. The route walk stops at each screen's resting state, so these are
 * opened on purpose and audited the same way.
 */
type DialogCase = {
  name: string
  path: (state: E2eState) => string
  /** The same readiness contract as `VisualRoute.ready`. */
  ready: (state: E2eState) => string
  open: (page: Page) => Promise<void>
}

const dialogCases: readonly DialogCase[] = [
  {
    name: 'the account menu',
    path: (state) => `/c/${state.communitySlug}`,
    ready: (state) => `text=${state.sessionTitle}`,
    open: async (page) => {
      await page.getByRole('button', { name: t('shell.account') }).click()
      await page.getByRole('menu', { name: t('shell.account') }).waitFor()
    },
  },
  {
    name: 'the session actions menu',
    path: (state) => `/c/${state.communitySlug}/sessions/${state.sessionId}`,
    ready: (state) => `text=${state.sessionTitle}`,
    open: async (page) => {
      const summary = page.getByRole('dialog', { name: t('summary.title') })
      await summary.getByRole('button', { name: t('summary.actions') }).click()
      await page.getByRole('menu', { name: t('summary.actionsSession') }).waitFor()
    },
  },
  {
    name: 'the score sheet',
    path: (state) => `/c/${state.communitySlug}/tournaments/${state.tournamentId}`,
    ready: (state) => `text=${state.tournamentName}`,
    open: async (page) => {
      // The fixture's scored group match; its label carries the score.
      const match = page.getByRole('button', { name: /27–29/ })
      await match.scrollIntoViewIfNeeded()
      await match.click()
      await page.getByRole('dialog', { name: 'Enter Score' }).waitFor()
    },
  },
  {
    name: 'the install sheet',
    path: (state) => `/c/${state.communitySlug}`,
    ready: (state) => `text=${state.sessionTitle}`,
    open: async (page) => {
      // Chromium never fires `beforeinstallprompt` under automation, and the
      // card that opens the sheet is only rendered once it has. WebKit already
      // shows the card through its user agent, so this is a no-op there.
      await page.evaluate(() => {
        window.dispatchEvent(new Event('beforeinstallprompt', { cancelable: true }))
      })
      await page.getByRole('button', { name: new RegExp(t('home.installApp')) }).click()
      await page.getByRole('dialog', { name: 'Install MAJADU App' }).waitFor()
    },
  },
]

async function violations(page: Page): Promise<string[]> {
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

  return [...wcag.violations, ...headings.violations].map(
    (violation) =>
      `${violation.id} (${violation.impact}): ${violation.nodes
        .map((node) => node.target.join(' '))
        .join(', ')}`,
  )
}

/** Readiness is data, not silence: `networkidle` never settles on a screen that
 * holds a WebSocket open, and it hides a failed read behind a timeout.
 * `visible`: the same words can sit in a hidden <option> of a picker, and a
 * readiness check that matches one is not waiting for the screen. */
async function openScreen(page: Page, path: string, ready: string): Promise<void> {
  await page.goto(path)
  await page.locator(ready).filter({ visible: true }).first().waitFor()
}

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

for (const route of a11yRoutes) {
  test(`${route.name} has no accessibility violations`, async ({ page }) => {
    await openScreen(page, route.path(state()), route.ready(state()))
    expect(await violations(page)).toEqual([])
  })
}

for (const dialogCase of dialogCases) {
  test(`${dialogCase.name} has no accessibility violations`, async ({ page }) => {
    await openScreen(page, dialogCase.path(state()), dialogCase.ready(state()))
    await dialogCase.open(page)
    expect(await violations(page)).toEqual([])
  })
}
