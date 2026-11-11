import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import type { Membership } from '../auth/api'
import { mockFetch } from '../test/fetchMock'
import { communityPath, resolveCommunity } from './selection'
import {
  COMMUNITY_STORAGE_KEY,
  readStoredSlug,
  writeStoredSlug,
} from './storage'
import { useCommunityConfig } from './useCommunityConfig'

const member = (id: string, slug: string, name: string): Membership => ({
  id,
  slug,
  name,
  role: 'member',
})

const acme = member('c1', 'acme', 'Acme')
const beta = member('c2', 'beta', 'Beta')

/**
 * A client per case with the retry off: the shipped policy retries once with a
 * backoff, which would only make every failure here two calls and a second long.
 */
function renderConfig<P>(hook: (props: P) => ReturnType<typeof useCommunityConfig>,
  initialProps: P) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: 0, gcTime: 0 } },
  })
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  )
  return renderHook(hook, { initialProps, wrapper })
}

describe('community selection', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('stores the selected slug', () => {
    expect(readStoredSlug()).toBeNull()
    writeStoredSlug('beta')
    expect(readStoredSlug()).toBe('beta')
    expect(window.localStorage.getItem(COMMUNITY_STORAGE_KEY)).toBe('beta')
    writeStoredSlug(null)
    expect(readStoredSlug()).toBeNull()
  })

  it('survives blocked storage instead of throwing', () => {
    const getItem = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    expect(readStoredSlug()).toBeNull()
    getItem.mockRestore()

    const setItem = vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('blocked')
    })
    expect(() => writeStoredSlug('acme')).not.toThrow()
    setItem.mockRestore()
  })

  it('prefers the URL slug, then the stored slug, then the first membership', () => {
    expect(resolveCommunity([acme, beta], 'beta', 'acme')).toEqual(beta)
    expect(resolveCommunity([acme, beta], null, 'beta')).toEqual(beta)
    expect(resolveCommunity([acme, beta], null, null)).toEqual(acme)
    expect(resolveCommunity([], 'acme', 'beta')).toBeNull()
  })

  it('never falls back to another membership for an unknown URL slug', () => {
    expect(resolveCommunity([acme, beta], 'ghost', 'beta')).toBeNull()
    expect(resolveCommunity([acme, beta], 'ghost', null)).toBeNull()
  })

  it('rewrites only the community segment', () => {
    expect(communityPath('/c/acme/sessions', 'beta')).toBe('/c/beta/sessions')
    expect(communityPath('/c/acme', 'beta')).toBe('/c/beta')
    expect(communityPath('/', 'beta')).toBe('/c/beta')
    expect(communityPath('/owner/communities', 'beta')).toBe('/c/beta')
    expect(communityPath('/c/acme', 'two words')).toBe('/c/two%20words')
  })
})

describe('useCommunityConfig', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('fetches again when the slug changes', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/acme/config': () => ({
        body: {
          effective: {
            'community.default_timezone': { value: 'Asia/Jakarta', source: 'platform' },
          },
        },
      }),
      'GET /api/c/beta/config': () => ({
        body: {
          effective: {
            'community.default_timezone': { value: 'Europe/Amsterdam', source: 'community' },
          },
        },
      }),
    })

    const { result, rerender } = renderConfig(
      ({ slug }: { slug: string }) => useCommunityConfig(slug),
      { slug: 'acme' },
    )

    expect(result.current.loading).toBe(true)
    await waitFor(() =>
      expect(result.current.config?.['community.default_timezone'].value).toBe('Asia/Jakarta'),
    )

    rerender({ slug: 'beta' })
    expect(result.current.loading).toBe(true)
    expect(result.current.config).toBeNull()

    await waitFor(() =>
      expect(result.current.config?.['community.default_timezone'].value).toBe(
        'Europe/Amsterdam',
      ),
    )

    const urls = fetchMock.mock.calls.map(([url]) => String(url))
    expect(urls).toEqual(expect.arrayContaining(['/api/c/acme/config', '/api/c/beta/config']))
  })

  it('reports a missing community distinctly from a failed request', async () => {
    mockFetch({
      'GET /api/c/ghost/config': () => ({ status: 404, body: { code: 'NOT_FOUND' } }),
      'GET /api/c/broken/config': () => ({ status: 500, body: { code: 'UNKNOWN' } }),
    })

    const missing = renderConfig((slug: string) => useCommunityConfig(slug), 'ghost')
    await waitFor(() => expect(missing.result.current.error).toBe('notFound'))

    const broken = renderConfig((slug: string) => useCommunityConfig(slug), 'broken')
    await waitFor(() => expect(broken.result.current.error).toBe('failed'))
  })

  it('does not request anything without a slug', () => {
    const fetchMock = mockFetch({})
    const { result } = renderConfig((slug: string | null) => useCommunityConfig(slug), null)

    expect(fetchMock).not.toHaveBeenCalled()
    expect(result.current.loading).toBe(false)
    expect(result.current.config).toBeNull()
  })
})
