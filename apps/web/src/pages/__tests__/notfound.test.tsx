import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

function handlers() {
  return {
    'GET /api/auth/me': () => ({
      body: { id: 'u1', displayName: 'Ada', platformOwner: false },
    }),
    'GET /api/communities': () => ({ body: { items: [membership] } }),
    'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
  }
}

describe('not found', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it('keeps an unknown path outside a community and names it', async () => {
    mockFetch(handlers())
    window.history.replaceState({}, '', '/nope')

    render(<App />)

    expect(await screen.findByRole('heading', { name: t('notFound.title') })).toBeInTheDocument()
    expect(screen.getByText(t('notFound.body', { path: '/nope' }))).toBeInTheDocument()
    // The redirect this route replaced would have rewritten the history entry.
    expect(window.location.pathname).toBe('/nope')
  })

  it('keeps an unknown path inside a community and links back to it', async () => {
    mockFetch(handlers())
    window.history.replaceState({}, '', '/c/acme/nope')

    render(<App />)

    expect(await screen.findByRole('heading', { name: t('notFound.title') })).toBeInTheDocument()
    expect(screen.getByText(t('notFound.body', { path: '/c/acme/nope' }))).toBeInTheDocument()
    expect(
      screen.getByRole('link', { name: t('notFound.communityHome') }),
    ).toHaveAttribute('href', '/c/acme')
    expect(window.location.pathname).toBe('/c/acme/nope')
  })
})
