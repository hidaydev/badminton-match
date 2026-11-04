import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../App'
import type { CommunityRole, Membership } from '../auth/api'
import { t } from '../i18n'
import { COMMUNITY_STORAGE_KEY } from './storage'
import { mockFetch } from '../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

const membership = (
  id: string,
  slug: string,
  name: string,
  role: CommunityRole = 'member',
): Membership => ({ id, slug, name, role })

const acme = membership('c1', 'acme', 'Acme')
const beta = membership('c2', 'beta', 'Beta')

const sessionHandlers = (items: Membership[]) => ({
  'GET /api/auth/me': () => ({ body: sessionUser }),
  'GET /api/communities': () => ({ body: { items } }),
})

const configHandlers = (timezone: Record<string, string>) =>
  Object.fromEntries(
    Object.entries(timezone).map(([slug, value]) => [
      `GET /api/c/${slug}/config`,
      () => ({
        body: {
          effective: {
            'community.default_timezone': { value, source: 'platform' },
          },
        },
      }),
    ]),
  )

describe('CommunityPicker', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/')
  })

  it('renders nothing when the account has no memberships', async () => {
    mockFetch(sessionHandlers([]))

    render(<App />)

    expect(await screen.findByRole('heading', { name: t('home.empty') })).toBeInTheDocument()
    expect(
      screen.queryByRole('combobox', { name: t('community.label') }),
    ).not.toBeInTheDocument()
  })

  it('lists memberships from the API and restores the stored slug', async () => {
    window.localStorage.setItem(COMMUNITY_STORAGE_KEY, 'beta')
    mockFetch(sessionHandlers([acme, beta]))

    render(<App />)

    const picker = await screen.findByRole('combobox', { name: t('community.label') })
    expect(picker).toHaveValue('beta')
    expect(screen.getAllByRole('option').map((option) => option.textContent)).toEqual([
      'Acme',
      'Beta',
    ])
  })

  it('switches community, reroutes and refetches without a login', async () => {
    window.history.replaceState({}, '', '/c/acme')
    const fetchMock = mockFetch({
      ...sessionHandlers([acme, beta]),
      ...configHandlers({ acme: 'Asia/Jakarta', beta: 'Europe/Amsterdam' }),
    })

    render(<App />)

    expect(await screen.findByRole('heading', { name: 'Acme' })).toBeInTheDocument()
    expect(await screen.findByText('Asia/Jakarta')).toBeInTheDocument()

    fireEvent.change(await screen.findByRole('combobox', { name: t('community.label') }), {
      target: { value: 'beta' },
    })

    await waitFor(() => expect(window.location.pathname).toBe('/c/beta'))
    expect(await screen.findByRole('heading', { name: 'Beta' })).toBeInTheDocument()
    expect(await screen.findByText('Europe/Amsterdam')).toBeInTheDocument()
    expect(window.localStorage.getItem(COMMUNITY_STORAGE_KEY)).toBe('beta')

    const urls = fetchMock.mock.calls.map(([url]) => String(url))
    expect(urls).toEqual(
      expect.arrayContaining(['/api/c/acme/config', '/api/c/beta/config']),
    )
    expect(urls.some((url) => url.endsWith('/auth/start'))).toBe(false)

    const betaCall = fetchMock.mock.calls.find(([url]) =>
      String(url).endsWith('/api/c/beta/config'),
    )
    expect((betaCall?.[1] as RequestInit).credentials).toBe('include')
  })

  it('keeps the selection after a reload', async () => {
    mockFetch({
      ...sessionHandlers([acme, beta]),
      ...configHandlers({ acme: 'Asia/Jakarta', beta: 'Europe/Amsterdam' }),
    })

    const first = render(<App />)

    const picker = await screen.findByRole('combobox', { name: t('community.label') })
    expect(picker).toHaveValue('acme')

    fireEvent.change(picker, { target: { value: 'beta' } })
    await waitFor(() => expect(window.location.pathname).toBe('/c/beta'))

    first.unmount()
    window.history.replaceState({}, '', '/')
    render(<App />)

    const reloaded = await screen.findByRole('combobox', { name: t('community.label') })
    expect(reloaded).toHaveValue('beta')
  })
})
