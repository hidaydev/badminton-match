import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('./auth/redirect', () => ({ redirectTo: vi.fn() }))
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from './App'
import { t } from './i18n'
import { jsonBody, mockFetch } from './test/fetchMock'
import { redirectTo } from './auth/redirect'

const unauth = () => ({ status: 401, body: { code: 'UNAUTHENTICATED' } })

const sessionUser = {
  id: 'u1',
  displayName: 'Ada',
  platformOwner: false,
}

describe('App auth gate', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    window.history.replaceState({}, '', '/')
  })

  it('shows the login screen without a session', async () => {
    mockFetch({ 'GET /api/auth/me': unauth })

    render(<App />)

    expect(await screen.findByRole('button', { name: t('login.action') })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: t('login.title') })).toBeInTheDocument()
    expect(screen.queryByRole('navigation')).not.toBeInTheDocument()
  })

  it('starts login with a same-origin returnTo and follows the authorize url', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': unauth,
      'POST /api/auth/start': () => ({
        body: { authorizeUrl: 'https://accounts.example/authorize?state=1', keyId: 'k1' },
      }),
    })
    window.history.pushState({}, '', '/c/acme/sessions?tab=next')

    render(<App />)
    fireEvent.click(await screen.findByRole('button', { name: t('login.action') }))

    await waitFor(() => expect(redirectTo).toHaveBeenCalledTimes(1))
    expect(redirectTo).toHaveBeenCalledWith('https://accounts.example/authorize?state=1')

    const startCall = fetchMock.mock.calls.find(([url]) => String(url).endsWith('/auth/start'))
    expect(startCall).toBeDefined()
    const [startUrl, startInit] = startCall as [string, RequestInit]
    expect(startUrl).toBe('/api/auth/start')
    expect(startInit.method).toBe('POST')
    expect(startInit.credentials).toBe('include')
    expect(jsonBody(startInit)).toEqual({ returnTo: '/c/acme/sessions?tab=next' })
  })

  it('clears the session on logout', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({
        body: { items: [{ id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }] },
      }),
      'POST /api/auth/logout': () => ({ status: 204 }),
    })

    render(<App />)
    expect(await screen.findByRole('link', { name: t('home.newSession') })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('nav.logout') }))

    expect(await screen.findByRole('button', { name: t('login.action') })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: t('nav.logout') })).not.toBeInTheDocument()
    const logoutCall = fetchMock.mock.calls.find(([url]) => String(url).endsWith('/auth/logout'))
    expect((logoutCall as [string, RequestInit])[1].credentials).toBe('include')
  })

  it('never writes session material to web storage', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [] } }),
    })

    render(<App />)
    await screen.findByRole('heading', { name: t('home.empty') })

    expect(window.localStorage.length).toBe(0)
    expect(window.sessionStorage.length).toBe(0)
  })

  it('asks for a reload when the server says this bundle is outdated', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({
        status: 410,
        body: { code: 'CLIENT_OUTDATED', detail: 'older contract' },
      }),
    })

    render(<App />)

    expect(await screen.findByText(t('app.outdated'))).toBeInTheDocument()
    expect(screen.getByRole('button', { name: t('app.outdated.action') })).toBeInTheDocument()
  })
})
