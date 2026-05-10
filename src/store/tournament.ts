import { create } from 'zustand'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
} from '../utils/tournament'
import type { GroupId, TournamentMatch, TournamentPair, TournamentSnapshot } from '../utils/tournament'

export type { GroupId, TournamentMatch, TournamentPair, TournamentSnapshot }
export type { MatchPhase, StandingRow } from '../utils/tournament'

interface TournamentState {
  name: string
  date: string
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
  addPairToGroup: (pairId: string, groupId: GroupId) => void
  removePairFromGroup: (pairId: string) => void
  confirmGroups: () => void
  resetGroups: () => void
  setMatchScore: (matchId: string, scoreA: number, scoreB: number) => void
  hydrateFromCloud: (snapshot: TournamentSnapshot) => void
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

export const useTournamentStore = create<TournamentState>()((set) => ({
  name: 'MAJADU Internal Tournament 2026',
  date: '2026-05-23',
  pairs: INITIAL_PAIRS,
  groups: EMPTY_GROUPS,
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

  confirmGroups: () =>
    set((s) => {
      const groupMatches = (['A', 'B', 'C', 'D'] as GroupId[]).flatMap((g) =>
        generateGroupMatches(g, s.groups[g])
      )
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      return { matches: propagateBracket(allMatches, s.groups, s.pairs) }
    }),

  resetGroups: () =>
    set({ groups: EMPTY_GROUPS, matches: [] }),

  setMatchScore: (matchId, scoreA, scoreB) =>
    set((s) => {
      const matches = s.matches.map((m) =>
        m.id === matchId ? { ...m, scoreA, scoreB } : m
      )
      return { matches: propagateBracket(matches, s.groups, s.pairs) }
    }),

  hydrateFromCloud: (snapshot) => set({
    name: snapshot.name,
    date: snapshot.date,
    pairs: snapshot.pairs,
    groups: snapshot.groups,
    matches: snapshot.matches,
  }),
}))
