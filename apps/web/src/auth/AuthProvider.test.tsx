import { beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

vi.mock('./redirect', () => ({ redirectTo: vi.fn() }))

import { SESSION_EXPIRED_EVENT } from '../api/errors'
import { currentCommunitySlug, setCommunitySlug } from '../legacy/queries/endpoints'
import { clearStoreDraft, prepareCommunityDraft, useStore } from '../legacy/store'
import { mockFetch } from '../test/fetchMock'
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
})
