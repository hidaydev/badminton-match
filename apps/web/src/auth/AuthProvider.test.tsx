import { beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

vi.mock('./redirect', () => ({ redirectTo: vi.fn() }))

import { SESSION_EXPIRED_EVENT } from '../api/errors'
import { currentCommunitySlug, setCommunitySlug } from '../legacy/queries/endpoints'
import { clearStoreDraft, prepareCommunityDraft, useStore } from '../legacy/store'
import { mockFetch } from '../test/fetchMock'
import { PRIVATE_IMAGE_CACHE } from '../pwa/cache'
import { AuthProvider } from './AuthProvider'
import { useAuth } from './AuthContext'

const FIRST_HOST = { id: 'u1', displayName: 'Host One', platformOwner: false }
const SECOND_HOST = { id: 'u2', displayName: 'Host Two', platformOwner: false }
const MEMBERSHIPS = {
  items: [{ id: 'c1', slug: 'acme', name: 'Acme', role: 'host' }],
}

function Probe() {
  const { user, loading } = useAuth()
  return <span>{loading ? 'loading' : (user?.displayName ?? 'signed out')}</span>
}

function renderAuth(client: QueryClient) {
  return render(
    <QueryClientProvider client={client}>
      <AuthProvider>
        <Probe />
      </AuthProvider>
    </QueryClientProvider>,
  )
}

function seedDraft(): void {
  window.history.replaceState({}, '', '/c/acme/session/players')
  setCommunitySlug('acme')
  prepareCommunityDraft('acme')
  useStore.getState().setTitle('Host One draft')
  useStore.getState().setCloudSessionId('session-of-h1')
  useStore.getState().setCloudVersion(4)
}

describe('AuthProvider session lifecycle', () => {
  beforeEach(() => {
    window.localStorage.clear()
    clearStoreDraft()
    setCommunitySlug('')
  })

  it('gives expiry the same teardown as logout so the next account starts empty', async () => {
    seedDraft()
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(['acme', 'session', 'session-of-h1'], { secret: 'h1 roster' })

    mockFetch({
      'GET /api/auth/me': () => ({ body: FIRST_HOST }),
      'GET /api/communities': () => ({ body: MEMBERSHIPS }),
    })

    const first = renderAuth(client)
    expect(await screen.findByText('Host One')).toBeInTheDocument()

    act(() => {
      window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT))
    })

    expect(await screen.findByText('signed out')).toBeInTheDocument()
    // The persisted draft, its pending write and the adapter slug are gone.
    expect(window.localStorage.getItem('badminton-store')).toBeNull()
    expect(currentCommunitySlug()).toBe('')
    expect(useStore.getState().session.title).toBe('')
    expect(useStore.getState().cloudSessionId).toBeNull()
    expect(useStore.getState().pendingPublish).toBeNull()
    // Nothing from the first host's community survives in the query cache.
    expect(client.getQueryCache().getAll()).toHaveLength(0)

    first.unmount()

    // A second host of the same community signs in on the same device.
    mockFetch({
      'GET /api/auth/me': () => ({ body: SECOND_HOST }),
      'GET /api/communities': () => ({ body: MEMBERSHIPS }),
    })
    setCommunitySlug('acme')
    prepareCommunityDraft('acme')

    renderAuth(client)
    expect(await screen.findByText('Host Two')).toBeInTheDocument()

    // The wizard would rehydrate a draft here; it must start empty.
    expect(useStore.getState().session.title).toBe('')
    expect(useStore.getState().players).toHaveLength(0)
    expect(useStore.getState().cloudSessionId).toBeNull()
    expect(window.localStorage.getItem('badminton-store') ?? '').not.toContain('Host One draft')
  })

  // REL-FE-05: the suite above never reached the retry ladder's failure arm.
  // Without a network, an installed app used to show the sign-in screen after
  // 12s, telling a signed-in player to sign in to a button that cannot work.
  it('stays loading offline and signs in only on the browser online event', async () => {
    vi.useFakeTimers()
    try {
      const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
      let online = false
      mockFetch({
        'GET /api/auth/me': () => {
          // A transport failure: no response arrived at all.
          if (!online) throw new TypeError('Failed to fetch')
          return { body: FIRST_HOST }
        },
        'GET /api/communities': () => {
          if (!online) throw new TypeError('Failed to fetch')
          return { body: MEMBERSHIPS }
        },
      })

      renderAuth(client)
      // Walk past the whole backoff ladder (1s + 3s + 8s).
      await act(async () => { await vi.advanceTimersByTimeAsync(20_000) })

      // Still the shell's loading state, not the sign-in screen.
      expect(screen.getByText('loading')).toBeInTheDocument()
      expect(screen.queryByText('signed out')).not.toBeInTheDocument()

      // The browser comes back; the shell decides again without a reload.
      online = true
      await act(async () => {
        window.dispatchEvent(new Event('online'))
        await vi.advanceTimersByTimeAsync(0)
      })
      expect(screen.getByText('Host One')).toBeInTheDocument()
    } finally {
      vi.useRealTimers()
    }
  })

  // The 401 branch has to stay first: a genuinely expired cookie is a
  // definitive answer even when the network is fine.
  it('still reaches the sign-in screen on a 401', async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    mockFetch({
      'GET /api/auth/me': () => ({
        status: 401,
        body: { status: 401, code: 'UNAUTHENTICATED', detail: 'no cookie' },
      }),
      'GET /api/communities': () => ({
        status: 401,
        body: { status: 401, code: 'UNAUTHENTICATED', detail: 'no cookie' },
      }),
    })

    renderAuth(client)

    expect(await screen.findByText('signed out')).toBeInTheDocument()
  })

  it('drops the origin-wide image cache when the session ends', async () => {
    const remove = vi.fn(async () => true)
    const original = Object.getOwnPropertyDescriptor(globalThis, 'caches')
    Object.defineProperty(globalThis, 'caches', { value: { delete: remove }, configurable: true })

    try {
      mockFetch({
        'GET /api/auth/me': () => ({ body: FIRST_HOST }),
        'GET /api/communities': () => ({ body: MEMBERSHIPS }),
      })
      renderAuth(new QueryClient({ defaultOptions: { queries: { retry: false } } }))
      expect(await screen.findByText('Host One')).toBeInTheDocument()

      act(() => {
        window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT))
      })

      expect(await screen.findByText('signed out')).toBeInTheDocument()
      await vi.waitFor(() => expect(remove).toHaveBeenCalledWith(PRIVATE_IMAGE_CACHE))
    } finally {
      if (original) Object.defineProperty(globalThis, 'caches', original)
      else Reflect.deleteProperty(globalThis, 'caches')
    }
  })
})
