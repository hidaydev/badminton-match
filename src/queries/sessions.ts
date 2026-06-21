import { useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, RpcError } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import type { SwapTarget, TeamSwapTarget } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import {
  replacePlayerNameInSnapshot,
  setAbsentPlayersInSnapshot,
  setScoreInSnapshot,
  swapPlayersInSnapshot,
  swapSlotsInSnapshot,
  swapTeamsInSnapshot,
  togglePlayedInSnapshot,
} from '../utils/sessionSnapshot'

async function invalidateSessionQueries(queryClient: ReturnType<typeof useQueryClient>, sessionId: string) {
  await Promise.all([
    queryClient.invalidateQueries({ queryKey: ['session', sessionId] }),
    queryClient.invalidateQueries({ queryKey: ['sessions'] }),
    queryClient.invalidateQueries({ queryKey: ['players'] }),
    queryClient.invalidateQueries({ queryKey: ['player'] }),
  ])
}

async function refetchOnVersionMismatch(
  queryClient: ReturnType<typeof useQueryClient>,
  sessionId: string,
  error: unknown,
  context: { previous?: CloudSnapshot | null } | undefined,
) {
  const isVersionMismatch =
    (error instanceof RpcError && error.code === '40001') ||
    (error instanceof Error && error.message.toLowerCase().includes('version mismatch'))
  if (isVersionMismatch) {
    try {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      return
    } catch {
      // fall through to rollback
    }
  }
  if (context?.previous !== undefined) {
    queryClient.setQueryData(['session', sessionId], context.previous)
  }
}

export function useListSessions(options?: { enabled?: boolean }) {
  return useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: listSessions,
    enabled: options?.enabled ?? true,
  })
}

export function useGetSession(sessionId: string | undefined) {
  return useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
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
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      if (!sessionId) return
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useTogglePlayed(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ key }: { key: string; nextPlayed: string[] }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated = togglePlayedInSnapshot(current, key)
      return await publishSession(sessionId, updated)
    },
    onMutate: async ({ key }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return togglePlayedInSnapshot(old, key)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated = setScoreInSnapshot(current, key, a, b)
      return await publishSession(sessionId, updated)
    },
    onMutate: async ({ key, a, b }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return setScoreInSnapshot(old, key, a, b)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useSwapPlayers(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (_vars: { t1: SwapTarget; t2: SwapTarget }) => {
      void _vars
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, current)
    },
    onMutate: async ({ t1, t2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return swapPlayersInSnapshot(old, t1, t2)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useSwapTeams(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (_vars: { t1: TeamSwapTarget; t2: TeamSwapTarget }) => {
      void _vars
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, current)
    },
    onMutate: async ({ t1, t2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return swapTeamsInSnapshot(old, t1, t2)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useSetAbsent(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ nextAbsent }: { nextAbsent: string[] }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated = setAbsentPlayersInSnapshot(current, nextAbsent)
      return await publishSession(sessionId, updated)
    },
    onMutate: async ({ nextAbsent }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return setAbsentPlayersInSnapshot(old, nextAbsent)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useReplacePlayer(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ playerId, newName }: { playerId: string; newName: string }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated = replacePlayerNameInSnapshot(current, playerId, newName)
      return await publishSession(sessionId, updated)
    },
    onMutate: async ({ playerId, newName }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return replacePlayerNameInSnapshot(old, playerId, newName)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
}

export function useSwapSlots(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { g1: SlotSwapTarget; g2: SlotSwapTarget }) => {
      void vars
      // Publish the optimistic cache directly. onMutate already applied
      // swapSlotsInSnapshot which rewrites schedule entries AND migrates
      // playedGames/gameScores keys to follow the swapped games.
      //
      // We must NOT re-apply swapSlotsInSnapshot here: it matches by
      // {slot, court} which have already been exchanged, so calling it
      // again would revert the swap (involutive). This is the same pattern
      // as useSwapPlayers/useSwapTeams: onMutate is the single mutation
      // source-of-truth, mutationFn just publishes the cache.
      //
      // The narrow risk: if a concurrent refetch overwrites the cache
      // between onMutate and mutationFn, the swap is lost from the payload.
      // cancelQueries in onMutate minimizes this window.
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, current)
    },
    onMutate: async ({ g1, g2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return swapSlotsInSnapshot(old, g1, g2)
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      void refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: (published) => {
      queryClient.setQueryData(['session', sessionId], published)
    },
    onSettled: async () => {
      await invalidateSessionQueries(queryClient, sessionId)
    },
  })
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
