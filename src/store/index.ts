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

// Combined state type
type AppState = SessionSlice & PlayersSlice & ScheduleSlice & FixMatchesSlice & UISlice

// Type for Zustand set function
export type SetState = (fn: (state: AppState) => Partial<AppState>) => void

// No-op setter — hanya dipakai untuk membangun initial state (migrate/reset).
// AMAN karena semua slice creators hanya memanggil `set` di dalam action
// functions (tidak saat konstruksi). Kalau suatu slice mulai memanggil `set`
// saat init, ini akan menghasilkan fungsi updater sebagai state — jangan.
const noopSet: SetState = () => undefined

function createInitialState(set: SetState): AppState {
  return {
    ...createSessionSlice(set),
    ...createPlayersSlice(set),
    ...createScheduleSlice(set),
    ...createFixMatchesSlice(set),
    ...createUISlice(set),
  }
}

export const useStore = create<AppState>()(
  persist(
    (set) => createInitialState(set),
    {
      name: 'badminton-store',
      version: 14,
      // Intentional: version bumps reset local state to prevent stale data
      // from causing issues with new schema. Users can re-create sessions.
      // Cloud-persisted sessions are unaffected by local store resets.
      migrate: () => createInitialState(noopSet),
    }
  )
)
