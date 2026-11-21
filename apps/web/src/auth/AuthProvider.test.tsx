import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
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

// REL-QA-07 (FE-49, and FE-05 for the offline arm): the bootstrap retry ladder
// and the `online` listener had no case at all, so a regression there shows up
// as a hall tablet stuck on a spinner or a signed-in player told to sign in.
// One case per arm of `load`'s catch block.
describe('AuthProvider bootstrap failures', () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it('keeps loading and retries when the failure is not definitive', async () => {
    // FE-05: a 503 is a server that will come back, so the shell must keep the
    // loading state rather than render sign-in while a retry is still pending.
    // Fake timers are needed here because the ladder is 1s + 3s + 8s; the
    // assertions use `getByText` rather than `findByText` because Testing
    // Library's own polling runs on the timers this test has frozen.
    //
    // Scope: the two rungs that are a retry. The terminal arm (what happens
    // once the ladder is spent) is FE-05's own change, so it is not asserted
    // here; this case is the ladder, which had no test at all before.
    vi.useFakeTimers()
    let meCalls = 0
    mockFetch({
      'GET /api/auth/me': () => {
        meCalls += 1
        return { status: 503, body: { code: 'UNAVAILABLE' } }
      },
    })

    renderAuth(new QueryClient({ defaultOptions: { queries: { retry: false } } }))

    // First attempt fails and arms the backoff; nothing flips the screen.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0)
    })
    expect(meCalls).toBe(1)
    expect(screen.getByText('loading')).toBeInTheDocument()

    // Rung one of BOOT_RETRY_MS = [1000, 3000, 8000] fires a second attempt.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000)
    })
    expect(meCalls).toBe(2)
    expect(screen.getByText('loading')).toBeInTheDocument()

    // Rung two fires a third: the ladder keeps climbing instead of giving up
    // after one failure.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(3_000)
    })
    expect(meCalls).toBe(3)
    expect(screen.getByText('loading')).toBeInTheDocument()
  })

  it('restarts the bootstrap at once when the browser comes back online', async () => {
    // The listener is the other half of the ladder: a phone that walks back
    // into signal should not wait out the 8s step. The timer is frozen and
    // advanced by zero, so a retry here can only come from the listener.
    vi.useFakeTimers()
    let meCalls = 0
    mockFetch({
      'GET /api/auth/me': () => {
        meCalls += 1
        if (meCalls === 1) return { status: 503, body: { code: 'UNAVAILABLE' } }
        return { body: FIRST_HOST }
      },
      'GET /api/communities': () => ({ body: MEMBERSHIPS }),
    })

    renderAuth(new QueryClient({ defaultOptions: { queries: { retry: false } } }))
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0)
    })
    expect(meCalls).toBe(1)
    expect(screen.getByText('loading')).toBeInTheDocument()

    // No timer elapses: the event alone re-runs the load.
    await act(async () => {
      window.dispatchEvent(new Event('online'))
      await vi.advanceTimersByTimeAsync(0)
    })

    expect(meCalls).toBe(2)
    expect(screen.getByText('Host One')).toBeInTheDocument()
  })

  it('goes to sign-in on a 401 instead of retrying', async () => {
    // The definitive answer stays first: no cookie means sign-in, and retrying
    // it would only delay the one screen that can fix it.
    let meCalls = 0
    mockFetch({
      'GET /api/auth/me': () => {
        meCalls += 1
        return { status: 401, body: { code: 'UNAUTHENTICATED' } }
      },
    })

    renderAuth(new QueryClient({ defaultOptions: { queries: { retry: false } } }))

    expect(await screen.findByText('signed out')).toBeInTheDocument()
    // One attempt: a 401 on the first call is the answer, not a transient. The
    // first rung of the ladder is 1s, so waiting past it would show a retry.
    await new Promise((resolve) => setTimeout(resolve, 1_500))
    expect(meCalls).toBe(1)
  })
})
