import type { SessionConfig, CourtTime } from '../types'
import { toTimeString, createCourtTime } from '../types'
import { timeToMinutes, minutesToTime, todayWIB } from '../utils/time'
import type { SetState } from './index'

const DEFAULT_SLOT_MINUTES = 20
const DEFAULT_COURT_TIMES: CourtTime[] = [
  { start: toTimeString('09:00'), end: toTimeString('11:00') },
  { start: toTimeString('09:00'), end: toTimeString('11:00') },
]

function makeDefaultSession(): SessionConfig {
  return {
    title: '',
    // WIB (bukan UTC) — sinkron dengan auto-lock backend yang pakai
    // Asia/Jakarta; toISOString bisa mundur 1 hari jam 00:00–06:59 WIB.
    date: todayWIB(),
    courts: 2,
    sessionStart: toTimeString('09:00'),
    slotMinutes: DEFAULT_SLOT_MINUTES,
    courtTimes: DEFAULT_COURT_TIMES,
    playerCount: 8,
    courtNames: [],
    locked: false,
  }
}

export interface SessionSlice {
  sessionId: string
  session: SessionConfig

  setCourts: (n: number) => void
  setSessionStart: (time: string) => void
  setSlotMinutes: (min: number) => void
  setCourtTime: (index: number, start: string, end: string) => void
  setPlayerCount: (n: number) => void
  setCourtName: (index: number, name: string) => void
  setTitle: (title: string) => void
  setDate: (date: string) => void
  lockSession: () => void
  resetSession: () => void
}

export function generateId() {
  return crypto.randomUUID().replace(/-/g, '').slice(0, 9)
}

export const createSessionSlice = (
  set: SetState
): SessionSlice => ({
  sessionId: generateId(),
  session: makeDefaultSession(),

  setCourts: (n) =>
    set((s) => {
      const prev = s.session.courtTimes
      const courtTimes = Array.from({ length: n }, (_, i) => prev[i] ?? { start: s.session.sessionStart, end: toTimeString('11:00') })
      return {
        session: {
          ...s.session,
          courts: n,
          courtTimes,
        },
      }
    }),

  setSessionStart: (time) =>
    set((s) => {
      const courtTimes = s.session.courtTimes.map((ct) => ({
        start: timeToMinutes(ct.start) < timeToMinutes(time) ? toTimeString(time) : ct.start,
        end: timeToMinutes(ct.end) <= timeToMinutes(time)
          ? toTimeString(minutesToTime(timeToMinutes(time) + s.session.slotMinutes))
          : ct.end,
      }))
      return {
        session: {
          ...s.session,
          sessionStart: toTimeString(time),
          courtTimes,
        },
      }
    }),

  setSlotMinutes: (min) =>
    set((s) => ({
      session: {
        ...s.session,
        slotMinutes: min,
      },
    })),

  setCourtTime: (index, start, end) =>
    set((s) => {
      try {
        const ct = createCourtTime(start, end)
        const courtTimes = [...s.session.courtTimes]
        courtTimes[index] = ct
        return {
          session: {
            ...s.session,
            courtTimes,
          },
        }
      } catch (e) {
        // If validation fails, don't update - return current state
        // The UI should show the error to the user
        console.warn('Invalid court time:', e)
        return s
      }
    }),

  setPlayerCount: (n) =>
    set((s) => ({ session: { ...s.session, playerCount: n } })),

  setCourtName: (index, name) =>
    set((s) => {
      const courtNames = [...s.session.courtNames]
      courtNames[index] = name
      return { session: { ...s.session, courtNames } }
    }),

  setTitle: (title) =>
    set((s) => ({ session: { ...s.session, title } })),

  setDate: (date) =>
    set((s) => ({ session: { ...s.session, date } })),

  lockSession: () =>
    set((s) => ({ session: { ...s.session, locked: true } })),

  resetSession: () =>
    set(() => ({
      sessionId: generateId(),
      session: makeDefaultSession(),
      players: [],
      fixMatches: [],
      schedule: [],
      lastResult: null,
      playedGames: [],
      gameScores: {},
      cloudSessionId: null,
      absentPlayers: [],
    })),
})
