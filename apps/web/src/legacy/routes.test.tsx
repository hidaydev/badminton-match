import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../auth/redirect', () => ({ redirectTo: vi.fn() }))
import { render, screen, waitFor } from '@testing-library/react'
import App from '../App'
import { t } from '../i18n'
import { mockFetch } from '../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

const acme = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

const bootstrap = {
  'GET /api/auth/me': () => ({ body: sessionUser }),
  'GET /api/communities': () => ({ body: { items: [acme] } }),
  // `GlobalAmbiguousNames` reads the whole roster on every legacy screen.
  'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
}

function mountAt(path: string) {
  window.history.replaceState({}, '', path)
  render(<App />)
}

describe('legacy routes', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  it('mounts the session list from its community URL', async () => {
    mockFetch({
      ...bootstrap,
      'GET /api/c/acme/sessions?limit=100': () => ({
        body: {
          items: [
            { id: 's1', title: 'Tuesday doubles', date: '2026-11-03', status: 'open' },
          ],
          total: 1,
        },
      }),
    })

    mountAt('/c/acme/sessions')

    expect(await screen.findByRole('heading', { name: t('sessions.title') })).toBeInTheDocument()
    expect(await screen.findByText('Tuesday doubles')).toBeInTheDocument()
  })

  it('returns to the login screen when a legacy request answers 401', async () => {
    mockFetch({
      ...bootstrap,
      'GET /api/c/acme/sessions?limit=100': () => ({
        status: 401,
        body: { code: 'UNAUTHENTICATED', detail: 'no session cookie' },
      }),
    })

    mountAt('/c/acme/sessions')

    // The page itself only has an error line; the shell has to notice the 401.
    expect(await screen.findByRole('button', { name: t('login.action') })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: t('sessions.title') })).not.toBeInTheDocument()
  })

  it('shows the reload banner when a legacy request answers CLIENT_OUTDATED', async () => {
    mockFetch({
      ...bootstrap,
      'GET /api/c/acme/sessions?limit=100': () => ({
        status: 410,
        body: { code: 'CLIENT_OUTDATED', detail: 'this client speaks an older contract' },
      }),
    })

    mountAt('/c/acme/sessions')

    expect(await screen.findByText(t('app.outdated'))).toBeInTheDocument()
    await waitFor(() =>
      expect(screen.getByRole('button', { name: t('app.outdated.action') })).toBeInTheDocument(),
    )
  })
})