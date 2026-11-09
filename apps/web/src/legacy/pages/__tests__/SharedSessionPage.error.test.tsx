import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from '../../../App'
import { t } from '../../../i18n'
import { mockFetch } from '../../../test/fetchMock'

const admin = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

function handlers(session: () => { status?: number; body?: unknown }) {
  return mockFetch({
    'GET /api/auth/me': () => ({
      body: { id: 'u1', displayName: 'Ada', platformOwner: false },
    }),
    'GET /api/communities': () => ({ body: { items: [admin] } }),
    'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
    'GET /api/c/acme/sessions/s1': session,
    'POST /api/c/acme/sessions/s1/ticket': () => ({
      body: { ticket: 'ticket', expiresIn: 60 },
    }),
  })
}

describe('shared session load failure', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    window.history.replaceState({}, '', '/c/acme/s/s1')
  })

  it('offers a retry instead of claiming the session is gone', async () => {
    // A 502 is the deploy-window failure the audit names; the read transport
    // does not back off on it, so the screen reaches its error state quickly.
    handlers(() => ({ status: 502, body: { code: 'BAD_GATEWAY', detail: 'upstream' } }))

    render(<App />)

    // The app's query client retries once, so the error state lands after it.
    expect(
      await screen.findByText(t('session.error.load'), {}, { timeout: 5_000 }),
    ).toBeInTheDocument()
    expect(screen.getByRole('button', { name: t('session.action.retry') })).toBeInTheDocument()
    // The alarming sentence is only for a 404.
    expect(screen.queryByText(t('session.error.notFound'))).not.toBeInTheDocument()
  })

  it('says not found only for a 404', async () => {
    handlers(() => ({ status: 404, body: { code: 'NOT_FOUND', detail: 'no session' } }))

    render(<App />)

    expect(await screen.findByText(t('session.error.notFound'))).toBeInTheDocument()
    expect(screen.queryByText(t('session.error.load'))).not.toBeInTheDocument()
  })
})
