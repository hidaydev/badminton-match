import { useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { WizardContext } from './context'
import type { WizardDraft, WizardStore } from './context'
import { computeSlotAllocation, minutesToTime, timeToMinutes, todayWIB } from './time'
import { generateId } from './id'
import type { MatchConstraint, SessionConfig } from './types'

const DEFAULT_SLOT_MINUTES = 20
const DEFAULT_START = '09:00'
const DEFAULT_END = '11:00'
const STORAGE_VERSION = 1

function makeDefaultSession(): SessionConfig {
  return {
    title: '',
    date: todayWIB(),
    courts: 2,
    sessionStart: DEFAULT_START,
    slotMinutes: DEFAULT_SLOT_MINUTES,
    courtTimes: [
      { start: DEFAULT_START, end: DEFAULT_END },
      { start: DEFAULT_START, end: DEFAULT_END },
    ],
    playerCount: 8,
    courtNames: [],
    locked: false,
  }
}

function makeDraft(): WizardDraft {
  return {
    serverSessionId: null,
    session: makeDefaultSession(),
    players: [],
    fixMatches: [],
    schedule: [],
    lastResult: null,
  }
}

function storageKey(slug: string): string {
  return `majadu.wizard.${slug}`
}

function loadDraft(slug: string): WizardDraft {
  try {
    const raw = window.localStorage.getItem(storageKey(slug))
    if (raw === null) return makeDraft()
    const parsed = JSON.parse(raw) as { version?: number; draft?: WizardDraft }
    if (parsed.version !== STORAGE_VERSION || !parsed.draft) return makeDraft()
    return { ...makeDraft(), ...parsed.draft }
  } catch {
    return makeDraft()
  }
}

function saveDraft(slug: string, draft: WizardDraft): void {
  try {
    window.localStorage.setItem(storageKey(slug), JSON.stringify({ version: STORAGE_VERSION, draft }))
  } catch {
    // A full or blocked storage must not break the wizard.
  }
}

export function WizardProvider({ slug, children }: { slug: string; children: ReactNode }) {
  const [draft, setDraft] = useState<WizardDraft>(() => loadDraft(slug))

  useEffect(() => {
    saveDraft(slug, draft)
  }, [slug, draft])

  const reset = useCallback(() => makeDraft(), [])

  const store = useMemo<WizardStore>(() => {
    const updateSession = (patch: Partial<SessionConfig>) =>
      setDraft((current) => ({ ...current, session: { ...current.session, ...patch } }))

    /** Changing a generator input invalidates the previous schedule. */
    const resetGenerated = (next: WizardDraft): WizardDraft => ({
      ...next,
      schedule: [],
      lastResult: null,
    })

    return {
      draft,
      totalGames: computeSlotAllocation(draft.session.courtTimes, draft.session.slotMinutes).totalGames,
      slotsPerCourt: computeSlotAllocation(draft.session.courtTimes, draft.session.slotMinutes).slotsPerCourt,

      setTitle: (title) => updateSession({ title }),
      setDate: (date) => updateSession({ date }),

      setCourts: (courts) =>
        setDraft((current) => {
          if (courts === current.session.courts) return current
          const previous = current.session.courtTimes
          const startMinutes = timeToMinutes(current.session.sessionStart)
          const defaultEnd =
            startMinutes >= timeToMinutes(DEFAULT_END)
              ? minutesToTime(startMinutes + current.session.slotMinutes)
              : DEFAULT_END
          const courtTimes = Array.from({ length: courts }, (_, i) => previous[i] ?? {
            start: current.session.sessionStart,
            end: defaultEnd,
          })
          return resetGenerated({ ...current, session: { ...current.session, courts, courtTimes } })
        }),

      setSessionStart: (time) =>
        setDraft((current) => {
          if (current.session.sessionStart === time) return current
          const courtTimes = current.session.courtTimes.map((ct) => ({
            start: timeToMinutes(ct.start) < timeToMinutes(time) ? time : ct.start,
            end:
              timeToMinutes(ct.end) <= timeToMinutes(time)
                ? minutesToTime(timeToMinutes(time) + current.session.slotMinutes)
                : ct.end,
          }))
          return resetGenerated({ ...current, session: { ...current.session, sessionStart: time, courtTimes } })
        }),

      setSlotMinutes: (minutes) =>
        setDraft((current) => {
          if (current.session.slotMinutes === minutes) return current
          return resetGenerated({ ...current, session: { ...current.session, slotMinutes: minutes } })
        }),

      setCourtTime: (index, start, end) =>
        setDraft((current) => {
          if (timeToMinutes(start) >= timeToMinutes(end)) return current
          const previous = current.session.courtTimes[index]
          if (previous && previous.start === start && previous.end === end) return current
          const courtTimes = [...current.session.courtTimes]
          courtTimes[index] = { start, end }
          return resetGenerated({ ...current, session: { ...current.session, courtTimes } })
        }),

      setCourtName: (index, name) =>
        setDraft((current) => {
          const courtNames = [...current.session.courtNames]
          courtNames[index] = name
          return { ...current, session: { ...current.session, courtNames } }
        }),

      setPlayerCount: (count) =>
        updateSession({ playerCount: Math.max(4, Math.min(60, count)) }),

      lockSession: () => updateSession({ locked: true }),

      resetDraft: () => setDraft(reset()),

      setServerSession: (id) => setDraft((current) => ({ ...current, serverSessionId: id })),

      addPlayer: (player) =>
        setDraft((current) => {
          if (current.players.length >= current.session.playerCount || current.players.length >= 60) {
            return current
          }
          return resetGenerated({
            ...current,
            players: [...current.players, { ...player, id: generateId() }],
          })
        }),

      addPlayers: (players) =>
        setDraft((current) => {
          const cap = Math.min(current.session.playerCount, 60)
          const available = Math.max(0, cap - current.players.length)
          const toAdd = players.slice(0, available)
          if (toAdd.length === 0) return current
          return resetGenerated({
            ...current,
            players: [...current.players, ...toAdd.map((p) => ({ ...p, id: generateId() }))],
          })
        }),

      updatePlayer: (id, patch) =>
        setDraft((current) => {
          const players = current.players.map((p) => (p.id === id ? { ...p, ...patch } : p))
          const currentPlayer = current.players.find((p) => p.id === id)
          const changesGeneratorInput =
            currentPlayer != null &&
            ((patch.gender !== undefined && patch.gender !== currentPlayer.gender) ||
              (patch.tier !== undefined && patch.tier !== currentPlayer.tier))
          if (!changesGeneratorInput) return { ...current, players }
          return resetGenerated({ ...current, players })
        }),

      removePlayer: (id) =>
        setDraft((current) => {
          const players = current.players.filter((p) => p.id !== id)
          const fixMatches = current.fixMatches
            .map((match) => ({
              ...match,
              slots: match.slots.map((slot) => (slot === id ? '' : slot)) as MatchConstraint['slots'],
            }))
            .filter((match) => match.slots.some((slot) => slot !== ''))
          return resetGenerated({ ...current, players, fixMatches })
        }),

      addFixMatch: (match) =>
        setDraft((current) => {
          const id = generateId()
          const next: MatchConstraint =
            match.mode === 'pinned'
              ? {
                  id,
                  slots: match.slots,
                  mode: 'pinned',
                  pinnedTime: match.pinnedTime ?? '',
                  pinnedCourt: match.pinnedCourt ?? 0,
                }
              : { id, slots: match.slots, mode: 'flexible' }
          return resetGenerated({ ...current, fixMatches: [...current.fixMatches, next] })
        }),

      updateFixMatch: (id, patch) =>
        setDraft((current) => ({
          ...resetGenerated(current),
          fixMatches: current.fixMatches.map((match) => {
            if (match.id !== id) return match
            const nextMode = patch.mode ?? match.mode
            if (nextMode === 'flexible') {
              return { id: match.id, slots: patch.slots ?? match.slots, mode: 'flexible' }
            }
            return {
              id: match.id,
              slots: patch.slots ?? match.slots,
              mode: 'pinned',
              pinnedTime: patch.pinnedTime ?? (match.mode === 'pinned' ? match.pinnedTime : ''),
              pinnedCourt: patch.pinnedCourt ?? (match.mode === 'pinned' ? match.pinnedCourt : 0),
            }
          }),
        })),

      duplicateFixMatch: (id) =>
        setDraft((current) => {
          const index = current.fixMatches.findIndex((match) => match.id === id)
          if (index === -1) return current
          const copy = { ...current.fixMatches[index], id: generateId() }
          const fixMatches = [...current.fixMatches]
          fixMatches.splice(index + 1, 0, copy)
          return resetGenerated({ ...current, fixMatches })
        }),

      removeFixMatch: (id) =>
        setDraft((current) =>
          resetGenerated({ ...current, fixMatches: current.fixMatches.filter((match) => match.id !== id) }),
        ),

      setResult: (result) =>
        setDraft((current) => ({ ...current, schedule: result.schedule, lastResult: result })),
    }
  }, [draft, reset])

  return <WizardContext.Provider value={store}>{children}</WizardContext.Provider>
}
