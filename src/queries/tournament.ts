import { useQuery, useMutation } from '@tanstack/react-query'
import { getTournament, listTournaments, createTournament, type TournamentMeta } from './endpoints'
import type { AnyTournamentSnapshot } from '../utils/teamTournament'
import type { GroupId, TournamentPair } from '../utils/tournament'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  assignGroupPics,
} from '../utils/tournament'
import { useOptimisticTournamentMutation } from './useOptimisticMutation'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

/** Daftar tournament (metadata) untuk halaman list. */
export function useListTournaments() {
  return useQuery<TournamentMeta[]>({
    queryKey: ['tournaments'],
    queryFn: listTournaments,
  })
}

export function useGetTournament(id: string) {
  return useQuery<AnyTournamentSnapshot | null>({
    queryKey: ['tournament', id],
    queryFn: () => getTournament(id),
    enabled: !!id,
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })
}

/** Create tournament (classic/team) → kembalikan { id, snapshot } (id dari Location). */
export function useCreateTournament() {
  return useMutation({
    mutationFn: (snap: AnyTournamentSnapshot) => createTournament(snap),
  })
}

export function useConfirmGroups(id: string) {
  return useOptimisticTournamentMutation<{
    localGroups: Record<GroupId, string[]>
    name: string
    date: string
    pairs: TournamentPair[]
  }>(
    id,
    (current, { localGroups, name, date, pairs }) => {
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const propagated = propagateBracket(allMatches, localGroups)
      const newMatches = assignGroupPics(pairs, localGroups, propagated)
      return {
        version: current?.version,
        name,
        date,
        pairs,
        groups: localGroups,
        matches: newMatches,
      }
    },
  )
}

export function useSetTournamentScore(id: string) {
  return useOptimisticTournamentMutation<{ matchId: string; scoreA: number; scoreB: number }>(
    id,
    (current, { matchId, scoreA, scoreB }) => {
      if (!current) return null
      const updated = current.matches.map((m) =>
        m.id === matchId ? { ...m, scoreA, scoreB } : m
      )
      const propagated = propagateBracket(updated, current.groups)
      return { ...current, matches: propagated }
    },
  )
}

export function useResetTournament(id: string) {
  return useOptimisticTournamentMutation<{
    name: string
    date: string
    pairs: TournamentPair[]
  }>(
    id,
    (current, { name, date, pairs }) => ({
      version: current?.version,
      name,
      date,
      pairs,
      groups: { A: [], B: [], C: [], D: [] },
      matches: [],
    }),
  )
}

export function useRegeneratePics(id: string) {
  // no optimistic update — result is non-deterministic (random shuffle);
  // applyOptimistic=false → onMutate hanya cancel, throw hanya di mutationFn.
  return useOptimisticTournamentMutation<undefined>(
    id,
    (current) => {
      if (!current) return null
      const newMatches = assignGroupPics(current.pairs, current.groups, current.matches)
      const unassigned = newMatches.some((m) => m.phase === 'group' && !m.picName)
      if (unassigned) throw new Error('Could not assign all PICs — please try again')
      return { ...current, matches: newMatches }
    },
    undefined,
    false,
  )
}
