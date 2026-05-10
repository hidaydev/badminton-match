import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getTournament, publishTournament, TOURNAMENT_ID } from './endpoints'
import type { TournamentSnapshot } from './types'
import type { GroupId, TournamentPair } from '../utils/tournament'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
} from '../utils/tournament'

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
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({
      localGroups,
      name,
      date,
      pairs,
    }: {
      localGroups: Record<GroupId, string[]>
      name: string
      date: string
      pairs: TournamentPair[]
    }) => {
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const newMatches = propagateBracket(allMatches, localGroups, pairs)
      await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: localGroups, matches: newMatches })
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}

export function useSetTournamentScore() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (_: { matchId: string; scoreA: number; scoreB: number }) => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) return
      await publishTournament(TOURNAMENT_ID, current)
    },
    onMutate: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
      const previous = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (previous) {
        const updated = previous.matches.map((m) =>
          m.id === matchId ? { ...m, scoreA, scoreB } : m
        )
        const propagated = propagateBracket(updated, previous.groups, previous.pairs)
        queryClient.setQueryData(['tournament', TOURNAMENT_ID], { ...previous, matches: propagated })
      }
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['tournament', TOURNAMENT_ID], context?.previous)
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}

export function useResetTournament() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({
      name,
      date,
      pairs,
    }: {
      name: string
      date: string
      pairs: TournamentPair[]
    }) => {
      await publishTournament(TOURNAMENT_ID, {
        name,
        date,
        pairs,
        groups: { A: [], B: [], C: [], D: [] },
        matches: [],
      })
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}
