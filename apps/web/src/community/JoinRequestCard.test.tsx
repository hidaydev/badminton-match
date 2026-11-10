import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../App'
import { t } from '../i18n'
import { mockFetch } from '../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

function renderHome() {
  window.localStorage.clear()
  window.history.replaceState({}, '', '/')
  return render(<App />)
}

describe('join request', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('sends the slug and says the request left', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [] } }),
      'POST /api/c/acme/join-requests': () => ({ status: 202, body: { status: 'accepted' } }),
    })

    renderHome()

    const input = await screen.findByLabelText(t('join.slug'))
    fireEvent.change(input, { target: { value: ' Acme ' } })
    fireEvent.click(screen.getByRole('button', { name: t('join.submit') }))

    await waitFor(() => {
      expect(screen.getByText(t('join.sent'))).toBeInTheDocument()
    })
    const call = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === '/api/c/acme/join-requests' &&
        (init as RequestInit | undefined)?.method === 'POST',
    )
    expect(call?.[0]).toBe('/api/c/acme/join-requests')
  })

  it('keeps the slug on screen while it is empty', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [] } }),
    })

    renderHome()
    await screen.findByLabelText(t('join.slug'))
    fireEvent.click(screen.getByRole('button', { name: t('join.submit') }))

    expect(screen.getByText(t('join.missing'))).toBeInTheDocument()
  })
})