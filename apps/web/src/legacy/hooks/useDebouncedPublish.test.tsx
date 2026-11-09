import { useState } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, render } from '@testing-library/react'
import { t } from '../../i18n'
import { useStore } from '../store'
import { communityQueryKey } from '../queries/keys'
import { ApiError, getSession, publishSession, setCommunitySlug } from '../queries/endpoints'
import { reportSessionExpired } from '../../api/errors'
import { AuthProvider } from '../../auth/AuthProvider'
import { useAuth } from '../../auth/AuthContext'
import { mockFetch } from '../../test/fetchMock'
import type { CloudSnapshot } from '../types'
import { useDebouncedPublish } from './useDebouncedPublish'

vi.mock('../queries/endpoints', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../queries/endpoints')>()
  return { ...actual, publishSession: vi.fn(), getSession: vi.fn() }
})

const SESSION = 's1'

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (error: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

function snapshot(version: number, title = 'first'): CloudSnapshot {
  const session = { ...useStore.getState().session, title }
  return {
    version,
    session,
    players: [],
    fixMatches: [],
    schedule: [],
    playedGames: [],
    gameScores: {},
    absentPlayers: [],
  }
}

const sessionKey = () => communityQueryKey('session', SESSION)

function setup(onError?: (message: string) => void, onSaved?: () => void) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  const api = { publishToCloud: () => {} }

  function Harness() {
    const hook = useDebouncedPublish(SESSION, onError, onSaved)
    api.publishToCloud = hook.publishToCloud
    return null
  }

  const view = render(
    <QueryClientProvider client={client}>
      <Harness />
    </QueryClientProvider>,
  )
  return { client, api, unmount: view.unmount }
}

/** Let queued promise callbacks (mutation, query, React effects) run. */
async function flush() {
  for (let i = 0; i < 10; i += 1) {
    await act(async () => {
      await Promise.resolve()
    })
  }
}

async function advance(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms)
  })
  await flush()
}

const publishMock = () => vi.mocked(publishSession)
const getSessionMock = () => vi.mocked(getSession)

beforeEach(() => {
  window.history.replaceState({}, '', '/c/plan')
  window.localStorage.clear()
  setCommunitySlug('plan')
  vi.useFakeTimers()
  useStore.getState().setCloudSessionId(SESSION)
  useStore.getState().setCloudVersion(9)
  useStore.getState().setTitle('first')
  useStore.getState().setPendingPublish(null)
  getSessionMock().mockResolvedValue(snapshot(12))
  publishMock().mockResolvedValue(snapshot(10))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('useDebouncedPublish', () => {
  it('publishes once for two edits inside the debounce window', async () => {
    const { api } = setup()

    act(() => api.publishToCloud())
    await advance(100)
    useStore.getState().setTitle('second')
    act(() => api.publishToCloud())
    await advance(300)

    expect(publishMock()).toHaveBeenCalledTimes(1)
    expect(publishMock().mock.calls[0][0]).toBe(SESSION)
    // The single request carries the state as it stood when the timer fired.
    expect(publishMock().mock.calls[0][1].session.title).toBe('second')
  })

  it('queues an edit made while a publish is in flight and sends it after the first settles', async () => {
    const inFlight = deferred<CloudSnapshot>()
    publishMock().mockImplementation(() => inFlight.promise)
    const { api } = setup()

    act(() => api.publishToCloud())
    await advance(300)
    expect(publishMock()).toHaveBeenCalledTimes(1)
    expect(publishMock().mock.calls[0][1].session.title).toBe('first')

    useStore.getState().setTitle('second')
    act(() => api.publishToCloud())
    // Nothing new goes out while the first write is still open.
    await advance(300)
    expect(publishMock()).toHaveBeenCalledTimes(1)

    inFlight.resolve(snapshot(4))
    await flush()
    await advance(300)

    expect(publishMock()).toHaveBeenCalledTimes(2)
    expect(publishMock().mock.calls[1][1].session.title).toBe('second')
  })

  it('sends the draft cloudVersion as the basis when the draft has one', async () => {
    const pending = deferred<CloudSnapshot>()
    publishMock().mockImplementation(() => pending.promise)
    const { api, client } = setup()
    client.setQueryData(sessionKey(), snapshot(5))

    act(() => api.publishToCloud())
    await advance(300)

    expect(publishMock().mock.calls[0][1].version).toBe(9)
  })

  it('falls back to the cached version when the draft has none', async () => {
    const pending = deferred<CloudSnapshot>()
    publishMock().mockImplementation(() => pending.promise)
    const { api, client } = setup()
    useStore.getState().setCloudVersion(null)
    client.setQueryData(sessionKey(), snapshot(5))

    act(() => api.publishToCloud())
    await advance(300)

    expect(publishMock().mock.calls[0][1].version).toBe(5)
  })

  it('reports the mapped save message and refetches the snapshot when the publish fails', async () => {
    const onError = vi.fn()
    const pending = deferred<CloudSnapshot>()
    publishMock().mockImplementation(() => pending.promise)
    const { api, client } = setup(onError)

    act(() => api.publishToCloud())
    await advance(300)
    expect(publishMock()).toHaveBeenCalledTimes(1)

    getSessionMock().mockResolvedValue(snapshot(11))
    pending.reject(new ApiError('being updated by another request', '55P03', 429))
    await flush()

    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith(t('session.contention'))
    expect(onError).not.toHaveBeenCalledWith(t('session.action.failed'))
    expect(getSessionMock()).toHaveBeenCalledWith(SESSION)
    expect(client.getQueryData<CloudSnapshot>(sessionKey())?.version).toBe(11)
  })

  it('publishes the queued edit once when the screen unmounts', async () => {
    const inFlight = deferred<CloudSnapshot>()
    publishMock().mockImplementation(() => inFlight.promise)
    const { client, api, unmount } = setup()
    client.setQueryData(sessionKey(), snapshot(5))

    act(() => api.publishToCloud())
    await advance(300)
    expect(publishMock()).toHaveBeenCalledTimes(1)

    useStore.getState().setTitle('second')
    act(() => api.publishToCloud())
    expect(publishMock()).toHaveBeenCalledTimes(1)

    unmount()
    await flush()

    expect(publishMock()).toHaveBeenCalledTimes(2)
    expect(publishMock().mock.calls[1][0]).toBe(SESSION)
    expect(publishMock().mock.calls[1][1].session.title).toBe('second')
    // A successful flush must not leave a "Changes not saved" record behind.
    expect(useStore.getState().pendingPublish).toBeNull()
  })

  it('publishes nothing when it unmounts with no edit pending', async () => {
    const { unmount } = setup()

    unmount()
    await flush()

    expect(publishMock()).not.toHaveBeenCalled()
  })

  it('records and reports a failed unmount flush instead of swallowing it', async () => {
    const onError = vi.fn()
    const { api, unmount } = setup(onError)
    publishMock().mockRejectedValueOnce(new ApiError('offline', null, null))

    act(() => api.publishToCloud())
    // The edit is still inside the debounce window when the screen goes away.
    unmount()
    await flush()

    expect(publishMock()).toHaveBeenCalledTimes(1)
    const pending = useStore.getState().pendingPublish
    expect(pending?.cloudSessionId).toBe(SESSION)
    expect(pending?.snapshot.session.title).toBe('first')
    expect(pending?.message).toBe(t('session.action.failed'))
    expect(onError).toHaveBeenCalledWith(t('session.action.failed'))
    // The retry record is persisted, not only in memory.
    expect(window.localStorage.getItem('badminton-store')).toContain('pendingPublish')
  })

  it('warns before unload and persists the unconfirmed draft while a publish is queued', async () => {
    const { api } = setup()

    act(() => api.publishToCloud())
    // Let the dirty state reach the beforeunload effect.
    act(() => {})

    const event = new Event('beforeunload', { cancelable: true })
    act(() => {
      window.dispatchEvent(event)
    })

    expect(event.defaultPrevented).toBe(true)
    const pending = useStore.getState().pendingPublish
    expect(pending?.cloudSessionId).toBe(SESSION)
    expect(pending?.snapshot.session.title).toBe('first')
  })

  it('keeps the close prompt armed while an edit is queued behind an in-flight publish', async () => {
    const inFlight = deferred<CloudSnapshot>()
    publishMock().mockImplementation(() => inFlight.promise)
    const { api } = setup()

    act(() => api.publishToCloud())
    await advance(300)
    useStore.getState().setTitle('second')
    act(() => api.publishToCloud())

    inFlight.resolve(snapshot(4))
    await flush()

    // The queued edit is scheduled but not sent yet; closing now must warn.
    const event = new Event('beforeunload', { cancelable: true })
    act(() => {
      window.dispatchEvent(event)
    })

    expect(event.defaultPrevented).toBe(true)
    expect(useStore.getState().pendingPublish?.snapshot.session.title).toBe('second')
  })

  it('reports success so the wizard can clear its saved-error banner', async () => {
    const onSaved = vi.fn()
    const { api } = setup(undefined, onSaved)

    act(() => api.publishToCloud())
    await advance(300)
    await flush()

    expect(publishMock()).toHaveBeenCalledTimes(1)
    expect(onSaved).toHaveBeenCalledTimes(1)
  })

  it('does not recreate the pending record when the flush rejects after expiry', async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
    })
    const api = { publishToCloud: () => {} }
    const inFlight = deferred<CloudSnapshot>()
    mockFetch({
      'GET /api/auth/me': () => ({
        body: { id: 'u1', displayName: 'Host', platformOwner: false },
      }),
      'GET /api/communities': () => ({ body: { items: [] } }),
    })

    let hookReady = false
    let hideHook = () => {}
    function AuthedHook() {
      const hook = useDebouncedPublish(SESSION)
      api.publishToCloud = hook.publishToCloud
      hookReady = true
      return null
    }

    function Controller() {
      const [shown, setShown] = useState(true)
      hideHook = () => setShown(false)
      return shown ? <AuthedHook /> : null
    }

    function AuthedGate() {
      const { user, loading } = useAuth()
      if (loading || !user) return null
      return <Controller />
    }

    render(
      <QueryClientProvider client={client}>
        <AuthProvider>
          <AuthedGate />
        </AuthProvider>
      </QueryClientProvider>,
    )
    for (let i = 0; i < 10 && !hookReady; i += 1) await flush()
    expect(hookReady).toBe(true)

    publishMock().mockImplementationOnce(() => inFlight.promise)
    act(() => api.publishToCloud())
    // Navigate away first: the flush request is already open when the cookie
    // expires, which is the order that produced the leak.
    act(() => hideHook())
    expect(publishMock()).toHaveBeenCalledTimes(1)

    act(() => {
      reportSessionExpired()
    })
    await flush()
    expect(useStore.getState().cloudSessionId).toBeNull()

    inFlight.reject(new ApiError('401 UNAUTHENTICATED', 'UNAUTHENTICATED', 401))
    await flush()

    expect(useStore.getState().pendingPublish).toBeNull()
    expect(window.localStorage.getItem('badminton-store') ?? '').not.toContain('pendingPublish')
  })
})