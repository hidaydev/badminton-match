import { useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, deleteSession, RpcError } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import type { Player } from '../store'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'

/** Deduplicate players by canonical name (lowercase, trimmed). Keeps first occurrence. */
function dedupPlayersByCanonicalName(players: Player[]): Player[] {
  const seen = new Set<string>()
  return players.filter(p => {
    const key = p.name.trim().toLowerCase()
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}
import { applyChange } from '../utils/swap'
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

async function refetchOnVersionMismatch(
  queryClient: ReturnType<typeof useQueryClient>,
  sessionId: string,
  error: unknown,
  context: { previous?: CloudSnapshot | null } | undefined,
) {
  // ROLLBACK FIRST (synchronous, immediate)
  if (context?.previous !== undefined) {
    queryClient.setQueryData(['session', sessionId], context.previous)
  }
  // On version mismatch, refetch latest so user can retry
  const isVersionMismatch =
    (error instanceof RpcError && error.code === '40001') ||
    (error instanceof Error && error.message.toLowerCase().includes('version mismatch'))
  if (isVersionMismatch) {
    try {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
    } catch {
      // ignore — stale cache (rolled back) is better than nothing
    }
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
      const isVersionMismatch =
        (error instanceof RpcError && error.code === '40001') ||
        (error instanceof Error && error.message.toLowerCase().includes('version mismatch'))
      if (isVersionMismatch) {
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
  return useMutation({
    mutationFn: async ({ key }: { key: string; nextPlayed: string[] }) => {
      void key
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, current)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
    },
  })
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
      void key; void a; void b
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, current)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateAllQueries(queryClient)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateAllQueries(queryClient)
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
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
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
  return useMutation({
    mutationFn: async ({ target, newName, playerName }: { target: ChangeTarget; newName: string; playerName: string }) => {
      const fresh = await getSession(sessionId)
      if (!fresh) throw new Error('no data')
      const newSchedule = applyChange(fresh.schedule, target, newName)
      // Rebuild players from schedule: every non-blank UUID must have an entry
      const scheduleIds = new Set<string>()
      for (const g of newSchedule) {
        for (const id of [...g.teamA, ...g.teamB]) {
          if (id.trim()) scheduleIds.add(id)
        }
      }
      const byId = new Map(fresh.players.map(p => [p.id, p]))
      if (newName.trim() && !byId.has(newName)) byId.set(newName, { id: newName, name: playerName, gender: 'M' as const, tier: 1 as const })
      const rebuilt = [...scheduleIds].map(id => byId.get(id) ?? { id, name: id, gender: 'M' as const, tier: 1 as const })
      const newPlayers = dedupPlayersByCanonicalName(rebuilt)
      // Debug: log mismatch between schedule and players
      const playerIds = new Set(newPlayers.map(p => p.id))
      const missing = [...scheduleIds].filter(id => !playerIds.has(id))
      if (missing.length > 0) {
        console.error('MISMATCH: schedule references IDs not in players:', missing)
        console.error('scheduleIds:', [...scheduleIds])
        console.error('playerIds:', [...playerIds])
      }
      const updated = {
        ...fresh,
        schedule: newSchedule,
        players: newPlayers,
        session: { ...fresh.session, playerCount: newPlayers.length },
      }
      return await publishSession(sessionId, updated)
    },
    onMutate: async ({ target, newName, playerName }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        const newSchedule = applyChange(old.schedule, target, newName)
        // Rebuild players from schedule: every non-blank UUID must have an entry
        const scheduleIds = new Set<string>()
        for (const g of newSchedule) {
          for (const id of [...g.teamA, ...g.teamB]) {
            if (id.trim()) scheduleIds.add(id)
          }
        }
        const byId = new Map(old.players.map(p => [p.id, p]))
        if (newName.trim() && !byId.has(newName)) byId.set(newName, { id: newName, name: playerName, gender: 'M' as const, tier: 1 as const })
        const rebuilt = [...scheduleIds].map(id => byId.get(id) ?? { id, name: id, gender: 'M' as const, tier: 1 as const })
        const newPlayers = dedupPlayersByCanonicalName(rebuilt)
        return {
          ...old,
          schedule: newSchedule,
          players: newPlayers,
          session: { ...old.session, playerCount: newPlayers.length },
        }
      })
      return { previous }
    },
    onError: async (error) => {
      console.error('changePlayer publish failed:', error)
      // Always refetch from server to get clean snapshot (avoid stale/corrupt cache)
      try {
        await queryClient.fetchQuery<CloudSnapshot | null>({
          queryKey: ['session', sessionId],
          queryFn: () => getSession(sessionId),
        })
      } catch {
        // ignore — better to have stale cache than crash
      }
    },
    onSuccess: async () => {
      // Don't set cache from server response — it can race with subsequent mutations.
      // Instead, refetch fresh data from server.
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateAllQueries(queryClient)
    },
  })
}

export function useLockSession(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, { 
        ...current, 
        session: { ...current.session, locked: true }
      })
    },
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return { ...old, session: { ...old.session, locked: true } }
      })
      return { previous }
    },
    onError: async (_err, _vars, context) => {
      await refetchOnVersionMismatch(queryClient, sessionId, _err, context)
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
    },
  })
}
