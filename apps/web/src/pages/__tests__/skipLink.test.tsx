import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

function handlers() {
  return {
    'GET /api/auth/me': () => ({
      body: { id: 'u1', displayName: 'Ada', platformOwner: false },
    }),
    'GET /api/communities': () => ({ body: { items: [membership] } }),
    'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
    'GET /api/c/acme/players?limit=50': () => ({ body: { items: [] } }),
    'GET /api/c/acme/config': () => ({ body: { effective: {}, scoringPresets: [] } }),
  }
}

/** Elements the browser would reach with Tab, in document order. */
function tabbables(): Element[] {
  return [
    ...document.querySelectorAll(
      'a[href], button:not([disabled]), select:not([disabled]), input:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ]
}

async function assertSkipLinkFirst() {
  const skip = await screen.findByRole('link', { name: t('shell.skipToContent') })
  expect(skip).toHaveAttribute('href', '#main')
  // Nothing in the header may come before it, or the first Tab misses it.
  expect(tabbables()[0]).toBe(skip)
  expect(document.querySelector('main#main')).not.toBeNull()
}

describe('skip link', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it('is the first tab stop in the community layout', async () => {
    mockFetch(handlers())
    window.history.replaceState({}, '', '/c/acme/players')

    render(<App />)

    await assertSkipLinkFirst()
  })

  it('is the first tab stop in the session layout', async () => {
    mockFetch(handlers())
    window.history.replaceState({}, '', '/c/acme/session/new')

    render(<App />)

    await assertSkipLinkFirst()
  })
})
