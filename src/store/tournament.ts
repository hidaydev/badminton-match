import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
} from '../utils/tournament'
import type { GroupId, TournamentMatch, TournamentPair } from '../utils/tournament'

export type { GroupId, TournamentMatch, TournamentPair }
export type { MatchPhase, StandingRow } from '../utils/tournament'

interface TournamentState {
  name: string
  date: string
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  groupsLocked: boolean
  matches: TournamentMatch[]
  addPairToGroup: (pairId: string, groupId: GroupId) => void
  removePairFromGroup: (pairId: string) => void
  lockGroups: () => void
  resetGroups: () => void
  setMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  hydrateFromCloud: (matches: TournamentMatch[]) => void
}

const INITIAL_PAIRS: TournamentPair[] = [
  { id: 'p1',  name: 'Dwi & Ismet' },
  { id: 'p2',  name: 'Vina & Fredi' },
  { id: 'p3',  name: 'Iky & Raihan' },
  { id: 'p4',  name: 'Azzam & Zainal' },
  { id: 'p5',  name: 'Dendi & Maul' },
  { id: 'p6',  name: 'Euis & Akid' },
  { id: 'p7',  name: 'Anas & Nindya' },
  { id: 'p8',  name: 'Faiz & Dimas' },
  { id: 'p9',  name: 'Fahmi & Lulud' },
  { id: 'p10', name: 'Agha & Lita' },
  { id: 'p11', name: 'Rakha & Visi' },
  { id: 'p12', name: 'Fakhri & Novian' },
  { id: 'p13', name: 'Hidayat & Zaid' },
  { id: 'p14', name: 'Boby & Andri' },
  { id: 'p15', name: 'Rudi & Ega' },
  { id: 'p16', name: 'Bowo & Didik' },
]

const EMPTY_GROUPS: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }

export const useTournamentStore = create<TournamentState>()(
  persist(
    (set) => ({
      name: 'MAJADU Internal Tournament 2026',
      date: '2026-05-23',
      pairs: INITIAL_PAIRS,
      groups: EMPTY_GROUPS,
      groupsLocked: false,
      matches: [],

      addPairToGroup: (pairId, groupId) =>
        set((s) => ({
          groups: { ...s.groups, [groupId]: [...s.groups[groupId], pairId] },
        })),

      removePairFromGroup: (pairId) =>
        set((s) => ({
          groups: {
            A: s.groups.A.filter((id) => id !== pairId),
            B: s.groups.B.filter((id) => id !== pairId),
            C: s.groups.C.filter((id) => id !== pairId),
            D: s.groups.D.filter((id) => id !== pairId),
          },
        })),

      lockGroups: () =>
        set((s) => {
          const groupMatches = (['A', 'B', 'C', 'D'] as GroupId[]).flatMap((g) =>
            generateGroupMatches(g, s.groups[g])
          )
          const allMatches = [...groupMatches, ...initKnockoutMatches()]
          return {
            groupsLocked: true,
            matches: propagateBracket(allMatches, s.groups, s.pairs),
          }
        }),

      resetGroups: () =>
        set({ groups: EMPTY_GROUPS, groupsLocked: false, matches: [] }),

      setMatchScore: (matchId, scoreA, scoreB) =>
        set((s) => {
          const matches = s.matches.map((m) =>
            m.id === matchId ? { ...m, scoreA, scoreB } : m
          )
          return { matches: propagateBracket(matches, s.groups, s.pairs) }
        }),

      hydrateFromCloud: (matches) => set({ matches }),
    }),
    {
      name: 'tournament-store',
      version: 2,
      migrate: () => ({
        name: 'MAJADU Internal Tournament 2026',
        date: '2026-05-23',
        pairs: INITIAL_PAIRS,
        groups: EMPTY_GROUPS,
        groupsLocked: false,
        matches: [],
      }),
    }
  )
)
