import { expect, test } from 'playwright/test'
import AxeBuilder from '@axe-core/playwright'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { signIn } from './session'
import { state } from './global-setup'
import { a11yRoutes } from './visual.routes'

/**
 * QA-19: axe reaches a minority of WCAG failures, so its value depends on how
 * much of the router it walks. This guard is what keeps the walk honest: a route
 * added to `App.tsx` either joins `a11yRoutes` or gets a dated exemption. It
 * parses the router rather than trusting a hand-maintained list, because the
 * list is exactly what drifted.
 */
type RouteDecl = { path: string; redirect: boolean; layout: boolean }

function declaredRoutes(): RouteDecl[] {
  const source = readFileSync(join(__dirname, '../apps/web/src/App.tsx'), 'utf8')
  const stack: { indent: number; path: string }[] = []
  const routes: RouteDecl[] = []
  for (const line of source.split('\n')) {
    const open = line.match(/^(\s*)<Route\b(.*)$/)
    if (open === null) continue
    const indent = open[1].length
    const rest = open[2]
    while (stack.length > 0 && stack[stack.length - 1].indent >= indent) stack.pop()
    const parent = stack.length > 0 ? stack[stack.length - 1].path : ''
    const declared = rest.match(/path="([^"]*)"/)
    if (declared === null) {
      // A layout route: it adds a nesting level but no path of its own.
      if (!rest.includes('/>')) stack.push({ indent, path: parent })
      continue
    }
    const path = declared[1]
    if (path.startsWith('/')) stack.length = 0
    const full = path.startsWith('/') ? path : [parent, path].filter(Boolean).join('/')
    const redirect =
      /<LegacyNavigate|<LegacySessionRedirect|<RootRedirect|<Navigate/.test(line)
    routes.push({ path: full, redirect, layout: !/element=/.test(line) })
    if (!rest.includes('/>')) stack.push({ indent, path: full })
  }
  return routes
}

function normalize(path: string): string {
  const known = new Set<string>()
  for (const [key, value] of Object.entries(state())) {
    if (typeof value === 'string' && value.length > 0) known.add(value)
  }
  return path
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