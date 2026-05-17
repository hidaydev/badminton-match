import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getTournament, publishTournament, TOURNAMENT_ID } from './endpoints'
import type { TournamentSnapshot } from './types'
import type { GroupId, TournamentPair } from '../utils/tournament'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  assignGroupPics,
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
      const propagated = propagateBracket(allMatches, localGroups, pairs)
      const newMatches = assignGroupPics(pairs, localGroups, propagated)
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
    mutationFn: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) throw new Error('no tournament data')
      const updated = current.matches.map((m) =>
        m.id === matchId ? { ...m, scoreA, scoreB } : m
      )
      const propagated = propagateBracket(updated, current.groups, current.pairs)
      const next = { ...current, matches: propagated }
      await publishTournament(TOURNAMENT_ID, next)
      return next
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

export function useRegeneratePics() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) throw new Error('no tournament data')
      const newMatches = assignGroupPics(current.pairs, current.groups, current.matches)
      const next = { ...current, matches: newMatches }
      await publishTournament(TOURNAMENT_ID, next)
      return next
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}
