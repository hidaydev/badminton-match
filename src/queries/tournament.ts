import { useQuery } from '@tanstack/react-query'
import { getTournament, TOURNAMENT_ID } from './endpoints'
import type { TournamentSnapshot } from './types'
import type { GroupId, TournamentPair } from '../utils/tournament'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  assignGroupPics,
} from '../utils/tournament'
import { useOptimisticTournamentMutation } from './useOptimisticMutation'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

export function useGetTournament() {
  return useQuery<TournamentSnapshot | null>({
    queryKey: ['tournament', TOURNAMENT_ID],
    queryFn: () => getTournament(TOURNAMENT_ID),
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })
}

export function useConfirmGroups() {
  return useOptimisticTournamentMutation<{
    localGroups: Record<GroupId, string[]>
    name: string
    date: string
    pairs: TournamentPair[]
  }>(
    TOURNAMENT_ID,
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

export function useSetTournamentScore() {
  return useOptimisticTournamentMutation<{ matchId: string; scoreA: number; scoreB: number }>(
    TOURNAMENT_ID,
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

export function useResetTournament() {
  return useOptimisticTournamentMutation<{
    name: string
    date: string
    pairs: TournamentPair[]
  }>(
    TOURNAMENT_ID,
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

export function useRegeneratePics() {
  // no optimistic update — result is non-deterministic (random shuffle);
  // applyOptimistic=false → onMutate hanya cancel, throw hanya di mutationFn.
  return useOptimisticTournamentMutation<undefined>(
    TOURNAMENT_ID,
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
