import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getTournament, publishTournament, TOURNAMENT_ID } from './endpoints'
import type { TournamentSnapshot } from './types'
import { isVersionMismatch } from './errors'
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
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const propagated = propagateBracket(allMatches, localGroups)
      const newMatches = assignGroupPics(pairs, localGroups, propagated)
      return await publishTournament(TOURNAMENT_ID, {
        version: current?.version,
        name,
        date,
        pairs,
        groups: localGroups,
        matches: newMatches,
      })
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<TournamentSnapshot | null>({
        queryKey: ['tournament', TOURNAMENT_ID],
        queryFn: () => getTournament(TOURNAMENT_ID),
      })
    },
    onError: (_err) => {
      console.error('Failed to confirm groups:', _err)
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
      const propagated = propagateBracket(updated, current.groups)
      const next = { ...current, matches: propagated }
      return await publishTournament(TOURNAMENT_ID, next)
    },
    onMutate: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
      const previous = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (previous) {
        const updated = previous.matches.map((m) =>
          m.id === matchId ? { ...m, scoreA, scoreB } : m
        )
        const propagated = propagateBracket(updated, previous.groups)
        queryClient.setQueryData(['tournament', TOURNAMENT_ID], { ...previous, matches: propagated })
      }
      return { previous }
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<TournamentSnapshot | null>({
        queryKey: ['tournament', TOURNAMENT_ID],
        queryFn: () => getTournament(TOURNAMENT_ID),
      })
    },
    onError: async (_err, _vars, context) => {
      // Rollback FIRST (immediate)
      if (context?.previous !== undefined) {
        queryClient.setQueryData(['tournament', TOURNAMENT_ID], context.previous)
      }
      // On version mismatch, refetch latest
      if (isVersionMismatch(_err)) {
        try {
          await queryClient.fetchQuery({
            queryKey: ['tournament', TOURNAMENT_ID],
            queryFn: () => getTournament(TOURNAMENT_ID),
          })
        } catch {
          // ignore
        }
      }
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
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      return await publishTournament(TOURNAMENT_ID, {
        version: current?.version,
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
    onSuccess: async () => {
      await queryClient.fetchQuery<TournamentSnapshot | null>({
        queryKey: ['tournament', TOURNAMENT_ID],
        queryFn: () => getTournament(TOURNAMENT_ID),
      })
    },
    onError: (_err) => {
      console.error('Failed to reset tournament:', _err)
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}

export function useRegeneratePics() {
  const queryClient = useQueryClient()
  // no optimistic update — result is non-deterministic (random shuffle); onSettled refetch is sufficient
  return useMutation({
    mutationFn: async () => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) throw new Error('no tournament data')
      const newMatches = assignGroupPics(current.pairs, current.groups, current.matches)
      const unassigned = newMatches.some((m) => m.phase === 'group' && !m.picName)
      if (unassigned) throw new Error('Could not assign all PICs — please try again')
      const next = { ...current, matches: newMatches }
      return await publishTournament(TOURNAMENT_ID, next)
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<TournamentSnapshot | null>({
        queryKey: ['tournament', TOURNAMENT_ID],
        queryFn: () => getTournament(TOURNAMENT_ID),
      })
    },
    onError: (_err) => {
      console.error('Failed to regenerate PICs:', _err)
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })
}
