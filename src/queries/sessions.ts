import { useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import { applySwap, type SwapTarget } from '../utils/swap'
import { applySlotSwap, type SlotSwapTarget } from '../utils/slotSwap'

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
    mutationFn: (snap: CloudSnapshot) => publishSession(sessionId!, snap),
    onSuccess: (_data, snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
    },
  })
}

export function useTogglePlayed(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ nextPlayed }: { key: string; nextPlayed: string[] }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated: CloudSnapshot = { ...current, playedGames: nextPlayed }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ nextPlayed }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, playedGames: nextPlayed }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextScores = { ...current.gameScores, [key]: { a, b } }
      const nextPlayed = current.playedGames.includes(key)
        ? current.playedGames
        : [...current.playedGames, key]
      const updated: CloudSnapshot = { ...current, gameScores: nextScores, playedGames: nextPlayed }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ key, a, b }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        const nextScores = { ...old.gameScores, [key]: { a, b } }
        const nextPlayed = old.playedGames.includes(key)
          ? old.playedGames
          : [...old.playedGames, key]
        return { ...old, gameScores: nextScores, playedGames: nextPlayed }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useSwapPlayers(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ t1, t2 }: { t1: SwapTarget; t2: SwapTarget }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextSchedule = applySwap(current.schedule, t1, t2)
      const updated: CloudSnapshot = { ...current, schedule: nextSchedule }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ t1, t2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, schedule: applySwap(old.schedule, t1, t2) }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useSetAbsent(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ nextAbsent }: { nextAbsent: string[] }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const updated: CloudSnapshot = { ...current, absentPlayers: nextAbsent }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ nextAbsent }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, absentPlayers: nextAbsent }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

export function useReplacePlayer(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ playerId, newName }: { playerId: string; newName: string }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextPlayers = current.players.map((p) =>
        p.id === playerId ? { ...p, name: newName } : p
      )
      const updated: CloudSnapshot = { ...current, players: nextPlayers }
      await publishSession(sessionId, updated)
      return updated
    },
    onMutate: async ({ playerId, newName }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return {
          ...old,
          players: old.players.map((p) => (p.id === playerId ? { ...p, name: newName } : p)),
        }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })
}

function migrateKeys<T>(
  record: Record<string, T>,
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): Record<string, T> {
  const k1 = `${g1.slot}-${g1.court}`
  const k2 = `${g2.slot}-${g2.court}`
  const next: Record<string, T> = {}
  for (const [k, v] of Object.entries(record)) {
    if (k === k1) next[k2] = v
    else if (k === k2) next[k1] = v
    else next[k] = v
  }
  return next
}

function migratePlayedGames(played: string[], g1: SlotSwapTarget, g2: SlotSwapTarget): string[] {
  const k1 = `${g1.slot}-${g1.court}`
  const k2 = `${g2.slot}-${g2.court}`
  return played.map((k) => {
    if (k === k1) return k2
    if (k === k2) return k1
    return k
  })
}

export function useSwapSlots(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (_vars: { g1: SlotSwapTarget; g2: SlotSwapTarget }) => {
      // onMutate already applied all transformations optimistically to the cache.
      // Re-applying applySlotSwap here would double-swap and revert to the original order,
      // because the function matches by {slot,court} which have already been exchanged.
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      await publishSession(sessionId, current)
      return current
    },
    onMutate: async ({ g1, g2 }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return {
          ...old,
          schedule: applySlotSwap(old.schedule, g1, g2),
          playedGames: migratePlayedGames(old.playedGames, g1, g2),
          gameScores: migrateKeys(old.gameScores, g1, g2),
        }
      })
      return { previous }
    },
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
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
