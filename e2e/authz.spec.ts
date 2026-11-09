import { expect, test } from 'playwright/test'
import type { Page } from 'playwright/test'
import { state } from './global-setup'

/**
 * QA-18: the role boundary, from both sides.
 *
 * Every other functional spec signs in through the OIDC stub, which has one
 * identity, so all of them are the platform owner. A router guard that never
 * sees a lower role, and a server gate that is never asked, are therefore
 * untested. `global-setup` mints a member session for `e2e-club`; these cases
 * replay it and assert both the hidden control and the refusal.
 *
 * The API cases use the same cookie through the browser's request context, so
 * they exercise the real session lookup, not a header the test invented.
 */

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173'
const slug = 'e2e-club'

async function asMember(page: Page): Promise<void> {
  const { memberCookie } = state()
  await page.context().addCookies([
    { name: 'majadu_session', value: memberCookie, url: baseURL },
  ])
}

function api(path: string): string {
  return `${baseURL}/api${path}`
}

test('a member is sent away from the admin settings screen', async ({ page }) => {
  await asMember(page)
  await page.goto(`/c/${slug}/settings`)
  await expect
    .poll(() => new URL(page.url()).pathname)
    .not.toContain('/settings')
  await expect(
    page.getByRole('heading', { name: 'Community settings' }),
  ).toHaveCount(0)
})

test('a member does not see the new session control', async ({ page }) => {
  await asMember(page)
  await page.goto(`/c/${slug}`)
  // The screen has rendered when its own data is on it; without this a missing
  // button can just mean the fixture has not loaded yet.
  await expect(page.getByText(state().sessionTitle).first()).toBeVisible()
  await expect(page.getByRole('button', { name: 'New Session' })).toHaveCount(0)
})

test('the API refuses a settings write from a member', async ({ page }) => {
  await asMember(page)
  const response = await page.request.patch(api(`/c/${slug}/settings`), {
    headers: { Origin: baseURL },
    data: {},
  })
  expect(response.status()).toBe(403)
})

test('the API refuses session creation from a member', async ({ page }) => {
  await asMember(page)
  const response = await page.request.post(api(`/c/${slug}/sessions`), {
    headers: { Origin: baseURL },
    data: { title: 'Member attempt', date: '2026-11-10', startTime: '19:00' },
  })
  expect(response.status()).toBe(403)
})

test('the API refuses the same write from an anonymous caller', async ({ page }) => {
  // No cookie is added: this is the door a probe or a logged-out browser uses.
  const response = await page.request.post(api(`/c/${slug}/sessions`), {
    headers: { Origin: baseURL },
    data: { title: 'Anonymous attempt', date: '2026-11-10', startTime: '19:00' },
  })
  expect(response.status()).toBe(401)
})
