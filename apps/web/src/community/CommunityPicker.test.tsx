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
  'GET /api/directory': () => ({ body: { items: [] } }),
})

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

  it('lists public communities and fills the join slug when one is picked', async () => {
    mockFetch({
      ...sessionHandlers([]),
      'GET /api/directory': () => ({
        body: { items: [{ slug: 'majadu', name: 'MAJADU' }] },
      }),
    })

    render(<App />)

    fireEvent.click(await screen.findByRole('button', { name: /MAJADU/ }))
    expect(screen.getByLabelText(t('join.slug'))).toHaveValue('majadu')
  })

  it('shows the my statistics shortcut when the account owns a player', async () => {
    mockFetch({
      ...sessionHandlers([acme]),
      'GET /api/c/acme/players?mine=1': () => ({
        body: {
          items: [
            {
              id: 'p1',
              name: 'Ani',
              gender: 'F',
              tier: null,
              userId: 'u1',
              createdAt: '2026-11-01 10:00:00+07',
              updatedAt: '2026-11-01 10:00:00+07',
            },
          ],
        },
      }),
    })

    render(<App />)

    fireEvent.click(
      await screen.findByRole('button', { name: new RegExp(t('home.card.myStats')) }),
    )
    await waitFor(() => expect(window.location.pathname).toBe('/c/acme/rankings/p1'))
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

  it('switches community and reroutes without a login', async () => {
    window.history.replaceState({}, '', '/c/acme')
    const fetchMock = mockFetch(sessionHandlers([acme, beta]))

    render(<App />)

    const picker = await screen.findByRole('combobox', { name: t('community.label') })
    expect(picker).toHaveValue('acme')

    fireEvent.change(picker, { target: { value: 'beta' } })

    await waitFor(() => expect(window.location.pathname).toBe('/c/beta'))
    expect(await screen.findByRole('combobox', { name: t('community.label') })).toHaveValue('beta')
    expect(window.localStorage.getItem(COMMUNITY_STORAGE_KEY)).toBe('beta')

    const urls = fetchMock.mock.calls.map(([url]) => String(url))
    expect(urls.some((url) => url.endsWith('/auth/start'))).toBe(false)
  })

  it('refuses a slug the account does not belong to instead of showing another community', async () => {
    window.history.replaceState({}, '', '/c/ghost/sessions')
    const fetchMock = mockFetch(sessionHandlers([acme, beta]))

    render(<App />)

    expect(
      await screen.findByRole('heading', { name: t('community.error.notFound') }),
    ).toBeInTheDocument()
    expect(screen.getByRole('link', { name: t('nav.home') })).toHaveAttribute('href', '/')
    const urls = fetchMock.mock.calls.map(([url]) => String(url))
    expect(urls.some((url) => url.includes('/api/c/ghost'))).toBe(false)
    expect(urls.some((url) => url.includes('/api/c/acme') || url.includes('/api/c/beta'))).toBe(false)
  })

  it('keeps the selection after a reload', async () => {
    mockFetch(sessionHandlers([acme, beta]))

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
