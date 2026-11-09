import { expect, test } from 'playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { t } from '../apps/web/src/i18n'

/**
 * ISO-15: the signed-in routes in `a11y.spec.ts` are not the first screen a
 * person sees. The login screen, the invitation error state and the legal pages
 * are public and were never measured. They are checked here without
 * `signIn`, so a regression on the entry path cannot hide behind the shell.
 *
 * The 404 and the tournament wizard dialogs are not in this list: the router
 * redirects every unknown path to `/` (there is no not-found screen yet), and
 * the wizard dialog states need a fixture that walks the wizard.
 */
const publicRoutes = [
  {
    name: 'login',
    path: '/',
    ready: `text=${t('login.title')}`,
  },
  {
    name: 'invite-signed-out',
    path: '/invites/not-a-real-token',
    ready: `text=${t('invite.title')}`,
  },
  {
    name: 'privacy',
    path: '/privacy',
    ready: `text=${t('privacy.title')}`,
  },
  {
    name: 'terms',
    path: '/terms',
    ready: `text=${t('terms.title')}`,
  },
] as const

for (const route of publicRoutes) {
  test(`${route.name} has no accessibility violations`, async ({ page }) => {
    await page.goto(route.path)
    await page.locator(route.ready).filter({ visible: true }).first().waitFor()

    const wcag = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze()
    // `heading-order` is tagged best-practice, so it needs its own pass; see
    // the same note in a11y.spec.ts.
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
