import { create } from 'zustand'
import { persist } from 'zustand/middleware'

import type { SessionSlice } from './sessionSlice'
import { createSessionSlice } from './sessionSlice'
import type { PlayersSlice } from './playersSlice'
import { createPlayersSlice } from './playersSlice'
import type { ScheduleSlice } from './scheduleSlice'
import { createScheduleSlice } from './scheduleSlice'
import type { FixMatchesSlice } from './fixMatchesSlice'
import { createFixMatchesSlice } from './fixMatchesSlice'
import type { UISlice } from './uiSlice'
import { createUISlice } from './uiSlice'

// Re-export types for backward compatibility
export type { Player, MatchConstraint, MatchConstraintFlexible, MatchConstraintPinned, ScheduleSlot, GameScore, CourtTime, SessionConfig, Gender, Tier } from '../types'
export type { FixMatch, FixMatchFlexible, FixMatchPinned } from '../types'
export { PLAYERS_PER_GAME } from '../types'
export { timeToMinutes, minutesToTime, computeTimeSlots, courtsAtTime, timeToSlotIndex } from '../utils/time'
export { selectSlotsPerCourt, selectTotalGames } from './selectors'

// Combined state type
type AppState = SessionSlice & PlayersSlice & ScheduleSlice & FixMatchesSlice & UISlice

// Type for Zustand set function
export type SetState = (fn: (state: AppState) => Partial<AppState>) => void

export const useStore = create<AppState>()(
  persist(
    (set) => ({
      ...createSessionSlice(set as SetState),
      ...createPlayersSlice(set as SetState),
      ...createScheduleSlice(set as SetState),
      ...createFixMatchesSlice(set as SetState),
      ...createUISlice(set as SetState),
    }),
    {
      name: 'badminton-store',
      version: 14,
      // Intentional: version bumps reset local state to prevent stale data
      // from causing issues with new schema. Users can re-create sessions.
      // Cloud-persisted sessions are unaffected by local store resets.
      migrate: () => ({
        ...createSessionSlice((fn) => fn as any), // eslint-disable-line @typescript-eslint/no-explicit-any
        ...createPlayersSlice((fn) => fn as any), // eslint-disable-line @typescript-eslint/no-explicit-any
        ...createScheduleSlice((fn) => fn as any), // eslint-disable-line @typescript-eslint/no-explicit-any
        ...createFixMatchesSlice((fn) => fn as any), // eslint-disable-line @typescript-eslint/no-explicit-any
        ...createUISlice((fn) => fn as any), // eslint-disable-line @typescript-eslint/no-explicit-any
      }),
    }
  )
)
