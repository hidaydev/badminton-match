import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../App'
import { t } from '../i18n'
import { mockFetch } from '../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const acme = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }
const entries = [
  { slug: 'beta', name: 'Beta Club' },
  { slug: 'gamma', name: 'Gamma Club' },
]

function renderAt(path: string) {
  window.localStorage.clear()
  window.sessionStorage.clear()
  window.history.replaceState({}, '', path)
  return render(<App />)
}

function mockSignedIn(handlers: Parameters<typeof mockFetch>[0] = {}) {
  return mockFetch({
    'GET /api/auth/me': () => ({ body: sessionUser }),
    'GET /api/communities': () => ({ body: { items: [acme] } }),
    ...handlers,
  })
}

describe('community directory', () => {
  beforeEach(() => {
    vi.unstubAllGlobals()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('offers the directory in the account menu of a plain member', async () => {
    mockSignedIn({
      'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
      'GET /api/c/acme/sessions?limit=100&offset=0': () => ({
        body: { items: [], total: 0, nextCursor: '' },
      }),
      'GET /api/c/acme/players?mine=1': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme')

    fireEvent.click(await screen.findByRole('button', { name: t('shell.account') }))

    const entry = screen.getByRole('menuitem', { name: t('nav.directory') })
    expect(entry).toHaveAttribute('href', '/directory')
  })

  it('renders the public directory for a signed-in account', async () => {
    mockSignedIn({
      'GET /api/directory': () => ({ body: { items: entries } }),
    })

    renderAt('/directory')

    expect(await screen.findByRole('heading', { name: t('directory.page.title') })).toBeInTheDocument()
    expect(await screen.findByRole('button', { name: /Beta Club/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Gamma Club/ })).toBeInTheDocument()
  })

  it('fills the join slug from a picked entry and sends the request', async () => {
    const fetchMock = mockSignedIn({
      'GET /api/directory': () => ({ body: { items: entries } }),
      'POST /api/c/beta/join-requests': () => ({ status: 202, body: { status: 'accepted' } }),
    })

    renderAt('/directory')

    fireEvent.click(await screen.findByRole('button', { name: /Beta Club/ }))
    const input = screen.getByLabelText(t('join.slug')) as HTMLInputElement
    expect(input.value).toBe('beta')

    fireEvent.click(screen.getByRole('button', { name: t('join.submit') }))

    await waitFor(() => {
      expect(screen.getByText(t('join.sent'))).toBeInTheDocument()
    })
    const call = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === '/api/c/beta/join-requests' &&
        (init as RequestInit | undefined)?.method === 'POST',
    )
    expect(call?.[0]).toBe('/api/c/beta/join-requests')
  })

  it('keeps the slug form when the directory returns nothing', async () => {
    mockSignedIn({
      'GET /api/directory': () => ({ body: { items: [] } }),
    })

    renderAt('/directory')

    expect(await screen.findByLabelText(t('join.slug'))).toBeInTheDocument()
  })

  it('links back to the current community', async () => {
    mockSignedIn({
      'GET /api/directory': () => ({ body: { items: entries } }),
    })

    renderAt('/directory')

    const link = await screen.findByRole('link', { name: t('directory.page.back', { name: 'Acme' }) })
    expect(link).toHaveAttribute('href', '/c/acme')
  })
})
