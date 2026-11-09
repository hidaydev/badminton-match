import { beforeEach, describe, expect, it, vi } from 'vitest'

async function loadStore() {
  // The store hydrates when the module is imported, so each case needs a fresh
  // module registry to see the seeded storage.
  vi.resetModules()
  return await import('./index')
}

describe('legacy store persistence', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/a')
  })

  it('migrates an old full-store blob to a tagged empty draft', async () => {
    window.localStorage.setItem(
      'badminton-store',
      JSON.stringify({ version: 14, state: { session: { locked: true, title: 'old' } } }),
    )

    const { useStore } = await loadStore()

    expect(useStore.getState().session.locked).toBe(false)
    const raw = JSON.parse(window.localStorage.getItem('badminton-store')!) as {
      version: number
      state: Record<string, unknown>
    }
    expect(raw.version).toBe(15)
    expect(raw.state.communitySlug).toBe('a')
  })

  it('persists only the draft and drops another community draft', async () => {
    const { useStore, prepareCommunityDraft } = await loadStore()
    const { setCommunitySlug } = await import('../queries/endpoints')

    prepareCommunityDraft('a')
    useStore.getState().setTitle('draft a')
    useStore.getState().setResult({
      schedule: [],
      playCount: {},
      sitCount: {},
      partnerWith: {},
      facedBy: {},
      unplacedFixMatches: [],
    })

    const forA = JSON.parse(window.localStorage.getItem('badminton-store')!) as {
      state: { communitySlug: string; session: { title: string }; lastResult?: unknown }
    }
    expect(forA.state.session.title).toBe('draft a')
    expect(forA.state.communitySlug).toBe('a')
    expect(forA.state.lastResult).toBeUndefined()

    setCommunitySlug('b')
    prepareCommunityDraft('b')

    expect(useStore.getState().session.title).toBe('')
    const forB = JSON.parse(window.localStorage.getItem('badminton-store')!) as {
      state: { communitySlug: string }
    }
    expect(forB.state.communitySlug).toBe('b')
  })

  it('persists the version basis so a reload cannot silently overwrite', async () => {
    const { useStore } = await loadStore()

    useStore.getState().setCloudSessionId('sess-1')
    useStore.getState().setCloudVersion(7)

    const raw = JSON.parse(window.localStorage.getItem('badminton-store')!) as {
      state: { cloudSessionId: string; cloudVersion: number | null }
    }
    expect(raw.state.cloudSessionId).toBe('sess-1')
    expect(raw.state.cloudVersion).toBe(7)

    // A different session cannot inherit the previous basis.
    useStore.getState().setCloudSessionId('sess-2')
    expect(useStore.getState().cloudVersion).toBeNull()
  })

  it('clears the persisted draft on logout', async () => {
    const { useStore, prepareCommunityDraft, clearStoreDraft } = await loadStore()
    prepareCommunityDraft('a')
    useStore.getState().setTitle('draft a')
    expect(window.localStorage.getItem('badminton-store')).not.toBeNull()

    clearStoreDraft()

    expect(window.localStorage.getItem('badminton-store')).toBeNull()
    expect(useStore.getState().session.title).toBe('')
  })

  it('refuses a pending publish when a different session is active', async () => {
    const { useStore, prepareCommunityDraft, recordPendingPublish } = await loadStore()
    const { setCommunitySlug } = await import('../queries/endpoints')
    setCommunitySlug('a')
    prepareCommunityDraft('a')
    useStore.getState().setCloudSessionId('s2')

    const saved = recordPendingPublish({
      cloudSessionId: 's1',
      snapshot: {
        version: 1,
        session: useStore.getState().session,
        players: [],
        fixMatches: [],
        schedule: [],
        playedGames: [],
        gameScores: {},
        absentPlayers: [],
      },
      message: 'offline',
      failedAt: Date.now(),
    })

    expect(saved).toBe(false)
    expect(useStore.getState().pendingPublish).toBeNull()
  })

  it('refuses a pending publish when the community slug is empty', async () => {
    const { useStore, prepareCommunityDraft, recordPendingPublish } = await loadStore()
    const { setCommunitySlug } = await import('../queries/endpoints')
    setCommunitySlug('a')
    prepareCommunityDraft('a')
    useStore.getState().setCloudSessionId('s1')
    // The expiry teardown clears the adapter slug while the id can still
    // match the record; this condition alone must refuse the write.
    setCommunitySlug('')

    const saved = recordPendingPublish({
      cloudSessionId: 's1',
      snapshot: {
        version: 1,
        session: useStore.getState().session,
        players: [],
        fixMatches: [],
        schedule: [],
        playedGames: [],
        gameScores: {},
        absentPlayers: [],
      },
      message: 'offline',
      failedAt: Date.now(),
    })

    expect(saved).toBe(false)
    expect(useStore.getState().pendingPublish).toBeNull()
  })

  it('keeps the first failure time and message when the record is written again', async () => {
    const { useStore, prepareCommunityDraft, recordPendingPublish } = await loadStore()
    const { setCommunitySlug } = await import('../queries/endpoints')
    setCommunitySlug('a')
    prepareCommunityDraft('a')
    useStore.getState().setCloudSessionId('s1')
    const snapshot = {
      version: 1,
      session: useStore.getState().session,
      players: [],
      fixMatches: [],
      schedule: [],
      playedGames: [],
      gameScores: {},
      absentPlayers: [],
    }
    const failedAt = Date.now() - 60_000

    expect(recordPendingPublish({
      cloudSessionId: 's1', snapshot, message: 'Someone else changed this session.', failedAt,
    })).toBe(true)
    // A beforeunload write passes no message and a new time; neither may
    // blank the explanation or extend the overwrite window.
    expect(recordPendingPublish({
      cloudSessionId: 's1', snapshot, message: null, failedAt: Date.now(),
    })).toBe(true)

    expect(useStore.getState().pendingPublish?.failedAt).toBe(failedAt)
    expect(useStore.getState().pendingPublish?.message).toBe('Someone else changed this session.')
  })
})