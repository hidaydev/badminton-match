import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from './App'
import { en } from './i18n/en'
import type { CommunityRole } from './auth/api'
import { routes, visibleNav } from './routes.manifest'
import { mockFetch } from './test/fetchMock'

const navKeys = (role: CommunityRole | null, platformOwner = false) =>
  visibleNav(role, platformOwner).map((entry) => entry.labelKey)

describe('routes manifest', () => {
  it('declares unique paths', () => {
    const paths = routes.map((route) => route.path)
    expect(new Set(paths).size).toBe(paths.length)
  })

  it('labels every entry through the dictionary', () => {
    for (const route of routes) {
      expect(Object.keys(en)).toContain(route.labelKey)
      expect(route.element).toBeTruthy()
      expect(typeof route.requiresAuth).toBe('boolean')
    }
  })

  it('filters nav by community role', () => {
    const member = ['nav.home', 'nav.sessions', 'nav.players', 'nav.rankings']
    expect(navKeys('member')).toEqual(member)
    expect(navKeys('host')).toEqual([...member, 'nav.tournaments'])
    expect(navKeys('admin')).toEqual([...member, 'nav.tournaments', 'nav.settings'])
    expect(navKeys(null)).toEqual(['nav.home'])
  })

  it('shows the owner-only entry to platform owners only', () => {
    expect(navKeys(null, true)).toEqual(['nav.home', 'nav.owner'])
    expect(navKeys('member', true)).toEqual([
      'nav.home',
      'nav.sessions',
      'nav.players',
      'nav.rankings',
      'nav.owner',
    ])
  })

  it('routes the community overview without listing it in the nav', () => {
    expect(routes.some((route) => route.path === '/c/:slug')).toBe(true)
    expect(visibleNav('admin', false).map((entry) => entry.path)).not.toContain('/c/:slug')
  })
})

describe('AppNav roles', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/c/acme/sessions')
  })

  const renderAs = (role: CommunityRole, platformOwner = false) => {
    mockFetch({
      'GET /api/auth/me': () => ({
        body: { id: 'u1', displayName: 'Ada', platformOwner },
      }),
      'GET /api/communities': () => ({
        body: { items: [{ id: 'c1', slug: 'acme', name: 'Acme', role }] },
      }),
    })
    return render(<App />)
  }

  it('hides administration entries from members', async () => {
    renderAs('member')

    expect(await screen.findByRole('link', { name: en['nav.sessions'] })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: en['nav.settings'] })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: en['nav.tournaments'] })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: en['nav.owner'] })).not.toBeInTheDocument()
  })

  it('shows administration entries to admins', async () => {
    renderAs('admin')

    expect(await screen.findByRole('link', { name: en['nav.settings'] })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: en['nav.tournaments'] })).toBeInTheDocument()
  })

  it('shows the owner entry to a platform owner', async () => {
    renderAs('member', true)

    expect(await screen.findByRole('link', { name: en['nav.owner'] })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: en['nav.settings'] })).not.toBeInTheDocument()
  })
})
