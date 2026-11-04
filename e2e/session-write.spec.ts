import { expect, request, test } from 'playwright/test'
import { t } from '../apps/web/src/i18n'
import { state } from './global-setup'
import { signIn } from './session'

/**
 * T-030: the screens that write. The fixture session is separate from the one
 * the visual baseline pins, so a score saved here cannot drift a snapshot.
 */
test.beforeEach(async ({ page }) => {
  await signIn(page)
})

function writableSession(projectName: string): string {
  const id = state().writableByProject[projectName]
  if (id === undefined) throw new Error(`no writable session for ${projectName}`)
  return id
}

test('the host saves a score and the page re-reads it', async ({ page }) => {
  const { communitySlug } = state()
  await page.goto(`/c/${communitySlug}/sessions/${writableSession(test.info().project.name)}`)
  await page
    .getByRole('heading', { name: `E2E Writable ${test.info().project.name}` })
    .waitFor()

  await page.getByLabel(t('session.column.sideA'), { exact: true }).fill('30')
  await page.getByLabel(t('session.column.sideB'), { exact: true }).fill('24')
  // Exact, because the absent panel also has a button whose name starts with
  // "Save" and it comes first in the DOM.
  await page.getByRole('button', { name: t('session.save'), exact: true }).click()

  // The write returns a new version and the page reloads; the games table only
  // shows a score once the server has it, so this is a read-after-write check.
  await expect(page.getByRole('cell', { name: '30–24' })).toBeVisible()
  await expect(page.getByRole('cell', { name: 'played' })).toBeVisible()
})

test('the host creates a share link a stranger can read', async ({ page }) => {
  const { communitySlug } = state()
  await page.goto(`/c/${communitySlug}/sessions/${writableSession(test.info().project.name)}`)
  await page
    .getByRole('heading', { name: `E2E Writable ${test.info().project.name}` })
    .waitFor()

  await page.getByRole('button', { name: t('session.share.show') }).click()
  await page.getByRole('button', { name: t('session.share.create') }).click()

  const open = page.getByRole('link', { name: t('session.share.open') })
  await expect(open).toBeVisible()
  const href = await open.getAttribute('href')
  expect(href).toMatch(/^\/s\/[^/]+$/)

  // The link is only useful if a browser with no session can read it. The
  // public screen is still a placeholder, so the API is what this asserts.
  const anonymous = await request.newContext({
    baseURL: process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173',
  })
  try {
    const read = await anonymous.get(`/api/s/${href!.slice('/s/'.length)}`)
    expect(read.status()).toBe(200)
  } finally {
    await anonymous.dispose()
  }
})
