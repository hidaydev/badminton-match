import type { MatchConstraint, PlayerId } from '../types'
import { toTimeString } from '../types'
import { generateId } from './sessionSlice'
import type { SetState } from './index'

export interface FixMatchesSlice {
  fixMatches: MatchConstraint[]

  addFixMatch: (m: Omit<MatchConstraint, 'id'>) => void
  updateFixMatch: (id: string, patch: Partial<Omit<MatchConstraint, 'id'>>) => void
  duplicateFixMatch: (id: string) => void
  removeFixMatch: (id: string) => void
}

export const createFixMatchesSlice = (
  set: SetState
): FixMatchesSlice => ({
  fixMatches: [],

  addFixMatch: (m) =>
    set((s) => {
      const id = generateId()
      const fm: MatchConstraint = m.mode === 'pinned'
        ? { id, slots: m.slots as [PlayerId, PlayerId, PlayerId, PlayerId], mode: 'pinned', pinnedTime: toTimeString((m as { pinnedTime?: string }).pinnedTime ?? ''), pinnedCourt: (m as { pinnedCourt?: number }).pinnedCourt ?? 0 }
        : { id, slots: m.slots as [PlayerId, PlayerId, PlayerId, PlayerId], mode: 'flexible' }
      return { fixMatches: [...s.fixMatches, fm], schedule: [], lastResult: null }
    }),

  updateFixMatch: (id, patch) =>
    set((s) => ({
      fixMatches: s.fixMatches.map((m) => {
        if (m.id !== id) return m
        const nextMode = patch.mode ?? m.mode
        if (nextMode === 'flexible') {
          // When switching to flexible, drop pinned fields
          return { id: m.id, slots: patch.slots ?? m.slots, mode: 'flexible' as const }
        }
        // When switching to pinned (or updating pinned), ensure pinned fields exist
        const base = m.mode === 'pinned' ? m : { ...m, pinnedTime: toTimeString(''), pinnedCourt: 0 }
        const merged = { ...base, ...patch, mode: 'pinned' as const }
        return {
          ...merged,
          pinnedTime: merged.pinnedTime ?? toTimeString(''),
          pinnedCourt: merged.pinnedCourt ?? 0,
        } as MatchConstraint
      }),
      schedule: [], lastResult: null,
    })),

  duplicateFixMatch: (id) =>
    set((s) => {
      const idx = s.fixMatches.findIndex((m) => m.id === id)
      if (idx === -1) return s
      const copy = { ...s.fixMatches[idx], id: generateId() }
      const next = [...s.fixMatches]
      next.splice(idx + 1, 0, copy)
      return { fixMatches: next, schedule: [], lastResult: null }
    }),

  removeFixMatch: (id) =>
    set((s) => ({ fixMatches: s.fixMatches.filter((m) => m.id !== id), schedule: [], lastResult: null })),
})
