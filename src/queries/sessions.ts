import { useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, deleteSession, RpcError } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'
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

/** Deteksi error version-mismatch (40001 / 'version mismatch') atau contention
 * (55P03 / 'being updated by another request'). */
function isVersionMismatchOrContention(error: unknown): boolean {
  return (
    (error instanceof RpcError && (error.code === '40001' || error.code === '55P03')) ||
    (error instanceof Error &&
      (error.message.toLowerCase().includes('version mismatch') ||
        error.message.toLowerCase().includes('being updated by another request')))
  )
}

/**
 * Factory mutation snapshot dengan AUTO-REBASE (solving dua admin score beda game):
 *
 * 1. onMutate  → optimistic update di cache (layar langsung berubah)
 * 2. mutationFn → publish cache (dengan version dari cache)
 * 3. kalau server TOLAK (version mismatch / contention): fetch data terbaru,
 *    TERAPKAN ULANG perubahan (vars) di atas snapshot segar, publish ulang (1x)
 *    → perubahan admin lain ikut terbawa, punya sendiri tidak hilang
 * 4. kalau rebase gagal / error lain → rollback + error (perilaku lama)
 *
 * Rebase di mutationFn (bukan onError) supaya sukses tetap masuk onSuccess
 * (tanpa toast error palsu) dan optimistic state tidak pernah flicker.
 */
function useSessionRebaseMutation<TVars>(
  sessionId: string,
  optimisticUpdate: (snap: CloudSnapshot, vars: TVars) => CloudSnapshot | null,
  invalidate: (queryClient: ReturnType<typeof useQueryClient>) => Promise<void>,
) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: TVars) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      try {
        return await publishSession(sessionId, current)
      } catch (err) {
        if (!isVersionMismatchOrContention(err)) throw err
        // Rebase: fetch latest, re-apply local change on top, publish with fresh version
        const fresh = await getSession(sessionId)
        if (!fresh) throw err
        const rebased = optimisticUpdate(fresh, vars)
        if (!rebased) throw err
        return await publishSession(sessionId, { ...rebased, version: fresh.version })
      }
    },
    onMutate: async (vars: TVars) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return optimisticUpdate(old, vars)
      })
      return { previous }
    },
    onError: async (_err, _vars, context) => {
      // Rollback — rebase sudah dicoba di mutationFn; kalau sampai di sini
      // berarti error non-rebase (lock/validasi) atau rebase gagal 2x.
      if (context?.previous !== undefined) {
        queryClient.setQueryData(['session', sessionId], context.previous)
      }
    },
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      await invalidate(queryClient)
    },
  })
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
  return useSessionRebaseMutation<{ key: string; nextPlayed: string[] }>(
    sessionId,
    (snap, { key }) => togglePlayedInSnapshot(snap, key),
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useSessionRebaseMutation<{ key: string; a: number; b: number }>(
    sessionId,
    (snap, { key, a, b }) => setScoreInSnapshot(snap, key, a, b),
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSwapPlayers(sessionId: string) {
  const queryClient = useQueryClient()
  return useSessionRebaseMutation<{ t1: SwapTarget; t2: SwapTarget }>(
    sessionId,
    (snap, { t1, t2 }) => swapPlayersInSnapshot(snap, t1, t2),
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSwapTeams(sessionId: string) {
  const queryClient = useQueryClient()
  return useSessionRebaseMutation<{ t1: TeamSwapTarget; t2: TeamSwapTarget }>(
    sessionId,
    (snap, { t1, t2 }) => swapTeamsInSnapshot(snap, t1, t2),
    () => invalidateSessionQueries(queryClient),
  )
}

export function useSetAbsent(sessionId: string) {
  const queryClient = useQueryClient()
  return useSessionRebaseMutation<{ nextAbsent: string[] }>(
    sessionId,
    (snap, { nextAbsent }) => setAbsentPlayersInSnapshot(snap, nextAbsent),
    () => invalidateAllQueries(queryClient),
  )
}

export function useReplacePlayer(sessionId: string) {
  const queryClient = useQueryClient()
  return useSessionRebaseMutation<{ playerId: string; newName: string }>(
    sessionId,
    (snap, { playerId, newName }) => replacePlayerNameInSnapshot(snap, playerId, newName),
    () => invalidateAllQueries(queryClient),
  )
}

export function useSwapSlots(sessionId: string) {
  const queryClient = useQueryClient()
  return useSessionRebaseMutation<{ g1: SlotSwapTarget; g2: SlotSwapTarget }>(
    sessionId,
    (snap, { g1, g2 }) => swapSlotsInSnapshot(snap, g1, g2),
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
      // Dedup by ID only (not canonical name — server validates canonical)
      const seen = new Set<string>()
      const newPlayers = [...scheduleIds]
        .map(id => byId.get(id) ?? { id, name: id, gender: 'M' as const, tier: 1 as const })
        .filter(p => { if (seen.has(p.id)) return false; seen.add(p.id); return true })
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
        // Dedup by ID only (not canonical name — server validates canonical)
        const seen = new Set<string>()
        const newPlayers = [...scheduleIds]
          .map(id => byId.get(id) ?? { id, name: id, gender: 'M' as const, tier: 1 as const })
          .filter(p => { if (seen.has(p.id)) return false; seen.add(p.id); return true })
        return {
          ...old,
          schedule: newSchedule,
          players: newPlayers,
          session: { ...old.session, playerCount: newPlayers.length },
        }
      })
      return { previous }
    },
    onError: async () => {
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
  return useSessionRebaseMutation<undefined>(
    sessionId,
    (snap) => ({ ...snap, session: { ...snap.session, locked: true } }),
    () => invalidateSessionQueries(queryClient),
  )
}
