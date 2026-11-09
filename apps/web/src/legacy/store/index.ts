import { create } from 'zustand'
import { persist } from 'zustand/middleware'

import { communitySlugFromPath } from '../../routes.manifest'
import { currentCommunitySlug } from '../queries/endpoints'
import type { SessionSlice } from './sessionSlice'
import { createSessionSlice } from './sessionSlice'
import type { PlayersSlice } from './playersSlice'
import { createPlayersSlice } from './playersSlice'
import type { ScheduleSlice } from './scheduleSlice'
import { createScheduleSlice } from './scheduleSlice'
import type { FixMatchesSlice } from './fixMatchesSlice'
import { createFixMatchesSlice } from './fixMatchesSlice'
import type { PendingPublish, UISlice } from './uiSlice'

export { PENDING_OVERWRITE_WINDOW_MS } from './uiSlice'
import { createUISlice } from './uiSlice'

// Combined state type
type AppState = SessionSlice & PlayersSlice & ScheduleSlice & FixMatchesSlice & UISlice

// Type for Zustand set function
export type SetState = (fn: (state: AppState) => Partial<AppState>) => void

/**
 * Only the in-progress wizard draft is persisted. Actions are rebuilt by the
 * initializer and `lastResult` is derived output, so neither is serialised.
 */
type PersistedDraft = {
  communitySlug: string
  sessionId: AppState['sessionId']
  session: AppState['session']
  players: AppState['players']
  fixMatches: AppState['fixMatches']
  schedule: AppState['schedule']
  playedGames: AppState['playedGames']
  gameScores: AppState['gameScores']
  absentPlayers: AppState['absentPlayers']
  cloudSessionId: AppState['cloudSessionId']
  cloudVersion: AppState['cloudVersion']
  pendingPublish: AppState['pendingPublish']
}

/** Before the legacy shell renders, the URL is the only source of the slug. */
function activeCommunitySlug(): string {
  return currentCommunitySlug() || communitySlugFromPath(window.location.pathname) || ''
}

/** Community the in-memory draft belongs to; `null` until a blob matches. */
let draftCommunitySlug: string | null = null

function createInitialState(set: SetState): AppState {
  return {
    ...createSessionSlice(set),
    ...createPlayersSlice(set),
    ...createScheduleSlice(set),
    ...createFixMatchesSlice(set),
    ...createUISlice(set),
  }
}

const noopSet: SetState = () => {}

function createEmptyDraft(): PersistedDraft {
  // Only the data fields are read; the action closures built here are discarded.
  const initial = createInitialState(noopSet)
  return {
    communitySlug: activeCommunitySlug(),
    sessionId: initial.sessionId,
    session: initial.session,
    players: initial.players,
    fixMatches: initial.fixMatches,
    schedule: initial.schedule,
    playedGames: initial.playedGames,
    gameScores: initial.gameScores,
    absentPlayers: initial.absentPlayers,
    cloudSessionId: initial.cloudSessionId,
    cloudVersion: initial.cloudVersion,
    pendingPublish: initial.pendingPublish,
  }
}

export const useStore = create<AppState>()(
  persist(
    (set) => createInitialState(set),
    {
      name: 'badminton-store',
      // v15 stores the draft only and tags it with the community it belongs to.
      // Older blobs were full-store snapshots without a tag, so they are
      // replaced by an empty draft instead of being applied to the wrong one.
      version: 15,
      partialize: (state): PersistedDraft => ({
        communitySlug: activeCommunitySlug(),
        sessionId: state.sessionId,
        session: state.session,
        players: state.players,
        fixMatches: state.fixMatches,
        schedule: state.schedule,
        playedGames: state.playedGames,
        gameScores: state.gameScores,
        absentPlayers: state.absentPlayers,
        cloudSessionId: state.cloudSessionId,
        cloudVersion: state.cloudVersion,
        pendingPublish: state.pendingPublish,
      }),
      merge: (persistedState, currentState) => {
        const saved = persistedState as PersistedDraft | undefined
        if (!saved || saved.communitySlug !== activeCommunitySlug()) {
          draftCommunitySlug = null
          return currentState
        }
        const { communitySlug, ...draft } = saved
        draftCommunitySlug = communitySlug
        return { ...currentState, ...draft }
      },
      // A version bump resets local draft state: the old blob cannot be
      // attributed to a community, and cloud-persisted sessions are unaffected.
      migrate: () => createEmptyDraft(),
      onRehydrateStorage: () => (_state, error) => {
        if (error) console.error('[store] hydration failed', error)
      },
    }
  )
)

/**
 * Make the in-memory draft belong to `slug`. Rehydration is synchronous with
 * localStorage, so a blob tagged for another community is never applied: the
 * stale draft is dropped instead.
 */
export function prepareCommunityDraft(slug: string): void {
  if (draftCommunitySlug === slug) return
  useStore.persist.rehydrate()
  if (draftCommunitySlug === slug) return
  useStore.getState().resetSession()
  draftCommunitySlug = slug
}

/** Drop the in-memory draft and its persisted copy (logout). */
export function clearStoreDraft(): void {
  useStore.getState().resetSession()
  useStore.persist.clearStorage()
  draftCommunitySlug = null
}

/**
 * Persist a failed publish, but only while the draft it belongs to is still
 * the active one. Expiry clears the draft synchronously, and the 401 handler
 * can run before the failing request's catch block; an unguarded write would
 * then recreate the previous account's record for the next account on this
 * device.
 */
export function recordPendingPublish(pending: PendingPublish): boolean {
  if (currentCommunitySlug() === '') return false
  const state = useStore.getState()
  if (state.cloudSessionId !== pending.cloudSessionId) return false
  const existing = state.pendingPublish
  const failedAt =
    existing !== null && existing.cloudSessionId === pending.cloudSessionId && existing.failedAt > 0
      ? existing.failedAt
      : pending.failedAt
  const message =
    pending.message ??
    (existing !== null && existing.cloudSessionId === pending.cloudSessionId ? existing.message : null)
  useStore.getState().setPendingPublish({
    ...pending,
    // Keep the original age and the message that first explained the record.
    failedAt,
    message,
  })
  return true
}