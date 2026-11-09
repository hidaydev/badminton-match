import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

/**
 * FE-20: optimistic concurrency seen from two browsers. The fixture gives every
 * project its own `E2E OCC` session (`occByProject`), separate from the
 * single-writer spec's session: `fullyParallel` runs this file beside
 * `session-write.spec.ts`, and two specs must not bump the same version.
 *
 * The three cases are one story and cannot be reordered: case 3 reads back the
 * first writer's score, so it has to happen before case 2 saves over it.
 *
 * The second writer's session reads are answered from a copy of the snapshot it
 * loaded. Two app behaviours force that: `useSessionRealtime` invalidates the
 * snapshot on the other writer's `session.changed` frame, and the granular save
 * re-reads the snapshot once and retries when its version is refused
 * (`legacy/queries/sessions.ts:74-97`). Without the frozen read the second
 * writer heals itself before the user ever sees the conflict.
 */

const FIRST = { a: 30, b: 19 }
/** Refused: it carries the version the first writer already bumped. */
const STALE = { a: 20, b: 30 }
/** Accepted after the reload, against the version the reload brought in. */
const SECOND = { a: 30, b: 24 }

function writableSession(projectName: string): string {
  const id = state().occByProject[projectName]
  if (id === undefined) throw new Error(`no writable session for ${projectName}`)
  return id
}

function sessionTitle(projectName: string): string {
  return `E2E OCC ${projectName}`
}

/** The row's score control: an empty row until the game has a score. */
async function openScoreEditor(page: Page): Promise<void> {
  await page
    .getByRole('button', { name: /Edit score$/ })
    .or(page.getByRole('button', { name: '+ score' }))
    .click()
}

async function fillAndSave(page: Page, score: { a: number; b: number }): Promise<void> {
  await openScoreEditor(page)
  const inputs = page.locator('input[type="number"]')
  await inputs.nth(0).fill(String(score.a))
  await inputs.nth(1).fill(String(score.b))
  await page.getByRole('button', { name: /Save/ }).last().click()
}

/**
 * Saves and waits for the server to accept it. The row shows the score as soon
 * as the mutation turns optimistic, so the button alone would let the next
 * writer race the request this one has not sent yet.
 */
async function saveAccepted(page: Page, sessionId: string, score: { a: number; b: number }): Promise<void> {
  const settled = page.waitForResponse(
    (response) =>
      response.request().method() === 'PATCH' &&
      response.url().includes(`/sessions/${sessionId}/games/`),
  )
  await fillAndSave(page, score)
  expect((await settled).status()).toBe(200)
}

/** The saved score is the row's label, so its digits name the button. */
function savedScore(score: { a: number; b: number }): RegExp {
  return new RegExp(`${score.a}–${score.b}`)
}

async function openSession(page: Page, slug: string, sessionId: string, title: string): Promise<void> {
  await page.goto(`/c/${slug}/sessions/${sessionId}`)
  await page.getByRole('dialog', { name: t('summary.title') }).getByText(title).waitFor()
}

test('two writers on one session: the stale save is refused, a reload shows the first score, then the next save lands', async ({ browser }) => {
  const info = test.info()
  const { writableCommunitySlug: slug } = state()
  const sessionId = writableSession(info.project.name)
  const title = sessionTitle(info.project.name)
  const detailUrl = `${info.project.use.baseURL ?? 'http://127.0.0.1:5173'}/api/c/${slug}/sessions/${sessionId}`

  // A service worker answers the app's own fetches on its own network stack,
  // where a context route never sees them, so the interceptor below needs the
  // page to be the one making the request.
  const options = {
    viewport: info.project.use.viewport,
    deviceScaleFactor: info.project.use.deviceScaleFactor,
    isMobile: info.project.use.isMobile,
    hasTouch: info.project.use.hasTouch,
    serviceWorkers: 'block' as const,
  }
  const firstContext = await browser.newContext(options)
  const secondContext = await browser.newContext(options)

  try {
    const first = await firstContext.newPage()
    const second = await secondContext.newPage()
    await signIn(first)
    await signIn(second)
    await openSession(first, slug, sessionId, title)
    await openSession(second, slug, sessionId, title)

    // The snapshot the second writer holds, read before the first writer bumps
    // anything. Every later read of it answers with this body.
    const held = await secondContext.request.get(detailUrl)
    expect(held.ok()).toBe(true)
    const frozen = await held.text()
    const detailRoute = new RegExp(`/api/c/${slug}/sessions/${sessionId}$`)
    await secondContext.route(detailRoute, (route) =>
      route.request().method() === 'GET'
        ? route.fulfill({ status: 200, contentType: 'application/json', body: frozen })
        : route.continue(),
    )

    // Case 1: the first writer's save is the only version bump on the server.
    await saveAccepted(first, sessionId, FIRST)

    // The second writer still holds the old version, so its save is refused
    // with the sentence that tells the user to reload.
    await fillAndSave(second, STALE)
    await expect(second.getByRole('alert').filter({ hasText: t('session.stale') })).toBeVisible()

    // The refused write left nothing behind on the server: the first writer
    // reloads and reads its own score back.
    await first.reload()
    // The page now carries the session title in its sr-only h1 as well as in
    // the summary dialog, so the wait has to name the surface it expects.
    await first
      .getByRole('dialog', { name: t('summary.title') })
      .getByText(title)
      .waitFor()
    await expect(first.getByRole('button', { name: savedScore(FIRST) })).toBeVisible()

    // Case 3: the reload brings the server's score, not the refused draft.
    await secondContext.unroute(detailRoute)
    await second.reload()
    await second.getByText(title).waitFor()
    await expect(second.getByRole('button', { name: savedScore(FIRST) })).toBeVisible()
    await expect(second.getByText(`${STALE.a}–${STALE.b}`)).toHaveCount(0)

    // Case 2: the next save carries the version the reload brought in.
    await saveAccepted(second, sessionId, SECOND)
    await expect(second.getByRole('button', { name: savedScore(SECOND) })).toBeVisible()
  } finally {
    await firstContext.close()
    await secondContext.close()
  }
})