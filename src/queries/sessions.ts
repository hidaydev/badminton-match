import { useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, deleteSession } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import { isVersionMismatch } from './errors'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'
import { rebuildPlayersFromSchedule } from '../utils/reconcilePlayers'
import { applyChange } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import {
  replacePlayerNameInSnapshot,
  setAbsentPlayersInSnapshot,
  setPlayedInSnapshot,
  setScoreInSnapshot,
  swapPlayersInSnapshot,
  swapSlotsInSnapshot,
  swapTeamsInSnapshot,
} from '../utils/sessionSnapshot'
import { useOptimisticSessionMutation } from './useOptimisticMutation'

async function invalidateSessionQueries(queryClient: ReturnType<typeof useQueryClient>) {
  await queryClient.invalidateQueries({ queryKey: ['sessions'] })
}

async function invalidateAllQueries(queryClient: ReturnType<typeof useQueryClient>) {
  await Promise.all([
    queryClient.invalidateQueries({ queryKey: ['sessions'] }),
    queryClient.invalidateQueries({ queryKey: ['players'] }),
    queryClient.invalidateQueries({ queryKey: ['player'] }),
  ])
}

export function useListSessions(options?: { enabled?: boolean }) {
  return useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: listSessions,
    enabled: options?.enabled ?? true,
  })
}

export function useGetSession(sessionId: string | undefined, options?: { refetchInterval?: number | false }) {
  return useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
    refetchInterval: options?.refetchInterval as unknown as number | false | undefined,
  })
}

export function usePublishSession(sessionId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (snap: CloudSnapshot) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      const next: CloudSnapshot = {
        ...snap,
        version: snap.version ?? current?.version,
        absentPlayers: snap.absentPlayers ?? current?.absentPlayers,
      }
      return publishSession(sessionId!, next)
    },
    onMutate: async () => {
      if (!sessionId) return undefined
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      return { previous }
    },
    onSuccess: async () => {
      if (!sessionId) return
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
    },
    onError: async (error, _vars, context) => {
      if (!sessionId) return
      // Rollback to previous snapshot
      if (context?.previous !== undefined) {
        queryClient.setQueryData(['session', sessionId], context.previous)
      }
      // On version mismatch, refetch the latest snapshot so the user can retry
      // without manually reloading the page.
      if (isVersionMismatch(error)) {
        try {
          await queryClient.fetchQuery<CloudSnapshot | null>({
            queryKey: ['session', sessionId],
            queryFn: () => getSession(sessionId),
          })
        } catch {
          // ignore — stale cache is better than nothing
        }
      }
    },
  })
}

export function useTogglePlayed(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const v = vars as { key: string; nextPlayed?: boolean | string[] }
      const { key } = v
      let nextPlayed: boolean | undefined
      if (typeof v.nextPlayed === 'boolean') nextPlayed = v.nextPlayed
      else if (Array.isArray(v.nextPlayed)) nextPlayed = (v.nextPlayed as string[]).includes(key)
      if (typeof nextPlayed === 'boolean') return setPlayedInSnapshot(old, key, nextPlayed)
      // Fallback toggle (legacy) — should not happen for new callers
      const isPlayed = old.playedGames.includes(key)
      return setPlayedInSnapshot(old, key, !isPlayed)
    },
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { key, a, b } = vars as { key: string; a: number; b: number }
      return setScoreInSnapshot(old, key, a, b)
    },
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSwapPlayers(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { t1, t2 } = vars as { t1: SwapTarget; t2: SwapTarget }
      return swapPlayersInSnapshot(old, t1, t2)
    },
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSwapTeams(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { t1, t2 } = vars as { t1: TeamSwapTarget; t2: TeamSwapTarget }
      return swapTeamsInSnapshot(old, t1, t2)
    },
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSetAbsent(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => setAbsentPlayersInSnapshot(old, (vars as { nextAbsent: string[] }).nextAbsent),
    () => invalidateAllQueries(queryClient),
  )
}

export function useReplacePlayer(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { playerId, newName } = vars as { playerId: string; newName: string }
      return replacePlayerNameInSnapshot(old, playerId, newName)
    },
    () => invalidateAllQueries(queryClient),
  )
}

export function useSwapSlots(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { g1, g2 } = vars as { g1: SlotSwapTarget; g2: SlotSwapTarget }
      return swapSlotsInSnapshot(old, g1, g2)
    },
    () => invalidateSessionQueries(queryClient),
  )
}

export function useFetchSession() {
  const queryClient = useQueryClient()
  return useCallback(
    (id: string) =>
      queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', id],
        queryFn: () => getSession(id),
      }),
    [queryClient],
  )
}

export function useDeleteSession() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (sessionId: string) => deleteSession(sessionId),
    onSettled: async () => {
      await invalidateAllQueries(queryClient)
    },
  })
}

export function useChangePlayer(sessionId: string) {
  const queryClient = useQueryClient()
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { target, newName, playerName } = vars as { target: ChangeTarget; newName: string; playerName: string }
      const newSchedule = applyChange(old.schedule, target, newName)
      const newPlayers = rebuildPlayersFromSchedule(newSchedule, old.players, newName, playerName)
      return {
        ...old,
        schedule: newSchedule,
        players: newPlayers,
        session: { ...old.session, playerCount: newPlayers.length },
      }
    },
    () => invalidateAllQueries(queryClient),
  )
}
