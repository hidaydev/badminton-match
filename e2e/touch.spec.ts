import { expect, test } from 'playwright/test'
import { signIn } from './session'
import { state } from './global-setup'
import type { E2eState } from './visual.routes'

/**
 * The touch floor from the design system: every pointer target is at least
 * 44x44 CSS pixels. It is measured instead of trusted because a class name
 * (`p-1.5`, `w-9`) says nothing about the box the browser lays out, and the
 * pseudo-element that expands a dense row's hit area does not change the
 * button's own box.
 */
type TouchRoute = {
  name: string
  path: (state: E2eState) => string
  /** A selector that proves the screen has rendered its data. */
  ready: (state: E2eState) => string
}

const routes: readonly TouchRoute[] = [
  { name: 'home', path: () => '/', ready: (state) => `text=${state.sessionTitle}` },
  {
    name: 'session setup',
    path: (state) => `/c/${state.communitySlug}/session/new`,
    ready: () => 'text=Session Setup',
  },
  {
    name: 'scoreboard',
    path: (state) => `/c/${state.communitySlug}/scoreboard`,
    ready: () => 'text=tap to score',
  },
  // `/export` is the old poster URL and redirects to the editor.
  {
    name: 'poster export',
    path: (state) => `/c/${state.communitySlug}/export`,
    ready: () => 'canvas',
  },
  // MAJ-03: these three carry the defect the source gate could not see. The
  // tournament screens hold the dense `hit44` rows, rankings renders the
  // scroll chip row, and the share page is the one screen rendered outside the
  // signed-in shell. `check-touch-targets.mjs` cannot read a template-literal
  // `className`, so the browser is the only instrument that sees their box.
  {
    name: 'rankings',
    path: (state) => `/c/${state.communitySlug}/rankings`,
    ready: () => 'h1',
  },
  {
    name: 'tournaments',
    path: (state) => `/c/${state.communitySlug}/tournaments`,
    ready: (state) => `text=${state.tournamentName}`,
  },
  {
    name: 'shared session',
    path: (state) => `/s/${state.shareCode}`,
    ready: (state) => `text=${state.shareTitle}`,
  },
]

test.beforeEach(async ({ page }) => {
  await signIn(page)
})

for (const route of routes) {
  test(`${route.name} keeps every control at the 44 px touch minimum`, async ({ page }) => {
    await page.goto(route.path(state()))
    await page.locator(route.ready(state())).filter({ visible: true }).first().waitFor()

    const small = await page.evaluate(() => {
      /**
       * The box the browser lays out and the box a finger can hit are not the
       * same thing. `hit44` keeps a 20-26px row visually dense on purpose and
       * expands the target with an `::after` pseudo-element, so measuring
       * `getBoundingClientRect()` on the button reports a failure for a control
       * that is actually 44x44 tappable. The pseudo-element's own rect is what
       * takes the tap, so it is the one measured; when it is absent or smaller,
       * the button's own box decides.
       */
      type Box = { width: number; height: number }

      function hitBox(element: HTMLElement, rect: DOMRect): Box {
        const pseudo = getComputedStyle(element, '::after')
        const content = pseudo.content
        if (content === 'none' || content === 'normal' || content === '') {
          return { width: rect.width, height: rect.height }
        }
        const width = Number.parseFloat(pseudo.width)
        const height = Number.parseFloat(pseudo.height)
        // `inset`-based pseudo-elements report `auto` for width/height; fall
        // back to the element box rather than pretending the size is 0.
        if (!Number.isFinite(width) || !Number.isFinite(height)) {
          return { width: rect.width, height: rect.height }
        }
        return { width: Math.max(width, rect.width), height: Math.max(height, rect.height) }
      }

      return [...document.querySelectorAll<HTMLElement>('button, select, a')]
        .map((element) => {
          const rect = element.getBoundingClientRect()
          const style = getComputedStyle(element)
          const hit = hitBox(element, rect)
          return {
            tag: element.tagName.toLowerCase(),
            text: (element.getAttribute('aria-label') ?? element.textContent ?? '')
              .trim()
              .slice(0, 40),
            className: element.className.toString().slice(0, 80),
            width: Math.round(hit.width),
            height: Math.round(hit.height),
            rendered:
              rect.width > 0 &&
              rect.height > 0 &&
              style.visibility !== 'hidden' &&
              style.display !== 'none',
            // The skip link is 1x1 until it is focused; a 1 px box is the
            // sr-only pattern, not a target somebody has to tap.
            clipped: rect.width <= 1 || rect.height <= 1,
          }
        })
        .filter((element) => element.rendered && !element.clipped)
        .filter((element) => element.width < 44 || element.height < 44)
        .map(
          (element) =>
            `${element.tag} ${element.width}x${element.height} "${element.text}" (${element.className})`,
        )
    })

    expect(small).toEqual([])
  })
}
