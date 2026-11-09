import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { t } from '../apps/web/src/i18n'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
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

/**
 * QA-19: axe reaches a minority of WCAG failures, so its value depends on how
 * much of the router it walks. This guard is what keeps the walk honest: a route
 * added to `App.tsx` either joins `a11yRoutes` or gets a dated exemption. It
 * parses the router rather than trusting a hand-maintained list, because the
 * list is exactly what drifted.
 */
type RouteDecl = { path: string; redirect: boolean; layout: boolean }

/**
 * A `<Route ...>` element is only self-closing when the line ends with `/>`.
 * Testing for `/>` anywhere matched the self-closing child inside
 * `element={<HomeLayout />}` and stopped every such route from becoming a
 * parent, which silently flattened the nesting and made the guard report every
 * screen as unvisited.
 */
function isSelfClosing(rest: string): boolean {
  return /\/>\s*$/.test(rest)
}

function declaredRoutes(): RouteDecl[] {
  const source = readFileSync(join(__dirname, '../apps/web/src/App.tsx'), 'utf8')
  const stack: { indent: number; path: string }[] = []
  const routes: RouteDecl[] = []
  for (const line of source.split('\n')) {
    const open = line.match(/^(\s*)<Route\b(.*)$/)
    if (open === null) continue
    const indent = open[1].length
    const rest = open[2]
    const indented = rest.replace(/\s+$/, '')
    while (stack.length > 0 && stack[stack.length - 1].indent >= indent) stack.pop()
    const parent = stack.length > 0 ? stack[stack.length - 1].path : ''
    const declared = indented.match(/path="([^"]*)"/)
    if (declared === null) {
      // A layout route: it adds a nesting level but no path of its own.
      if (!isSelfClosing(indented)) stack.push({ indent, path: parent })
      continue
    }
    const path = declared[1]
    if (path.startsWith('/')) stack.length = 0
    const full = path.startsWith('/') ? path : [parent, path].filter(Boolean).join('/')
    const redirect =
      /<LegacyNavigate|<LegacySessionRedirect|<RootRedirect|<Navigate/.test(line)
    routes.push({ path: full, redirect, layout: !/element=/.test(line) })
    if (!isSelfClosing(indented)) stack.push({ indent, path: full })
  }
  return routes
}

function normalize(path: string): string {
  // `players` is baselined on a filtered URL, so a route's query string is not
  // part of the screen's identity; neither is a fragment.
  const [pathname] = path.split(/[?#]/)
  const known = new Set<string>()
  for (const [key, value] of Object.entries(state())) {
    if (typeof value === 'string' && value.length > 0) known.add(value)
  }
  return pathname
    .split('/')
    .map((segment) => (segment.startsWith(':') || known.has(segment) ? '*' : segment))
    .join('/')
}

function exemptions(): string[] {
  const document = JSON.parse(
    readFileSync(join(__dirname, 'a11y-exemptions.json'), 'utf8'),
  ) as { entries: { path: string; expires: string }[] }
  const today = new Date().toISOString().slice(0, 10)
  for (const entry of document.entries) {
    expect(entry.expires >= today, `a11y exemption expired: ${entry.path}`).toBe(true)
  }
  return document.entries.map((entry) => entry.path)
}

test('every non-dev route is in the a11y walk or has a dated exemption', () => {
  const covered = new Set<string>()
  for (const route of a11yRoutes) {
    const path = route.path(state())
    if (path.startsWith('http')) continue
    covered.add(normalize(path))
  }
  const exempt = new Set(exemptions())
  const missing: string[] = []
  for (const route of declaredRoutes()) {
    if (route.redirect || route.layout) continue
    if (route.path === '*' || route.path.includes('*')) continue
    if (route.path.includes('/dev/') || route.path.endsWith('/dev')) continue
    const normalized = normalize(route.path)
    if (covered.has(normalized) || exempt.has(normalized)) continue
    missing.push(normalized)
  }
  expect(missing, `routes with no a11y walk and no exemption: ${missing.join(', ')}`)
    .toEqual([])
})


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
