import { useCallback, useEffect, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, deleteSession, getGame, patchGameScore, patchGamePlayed, patchAbsentPlayers, patchGameSkipped, swapMembers } from './endpoints'
import type { GranularSwapTarget } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import { isVersionMismatch, isLockedError, isContentionError } from './errors'
import type { SwapTarget, TeamSwapTarget } from '../utils/swap'
import { rebuildPlayersFromSchedule } from '../utils/reconcilePlayers'
import { applyChange } from '../utils/swap'
import type { SlotSwapTarget } from '../utils/slotSwap'
import {
  replacePlayerNameInSnapshot,
  setAbsentPlayersInSnapshot,
  setPlayedInSnapshot,
  setScoreInSnapshot,
  setSkippedInSnapshot,
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
    queryClient.invalidateQueries({ queryKey: ['ratings'] }),
  ])
}

// ── Granular optimistic lifecycle (shared) ───────────────────────────────────
// Satu sumber untuk pola onMutate/onError/onSuccess yang dipakai mutation
// granular: cancel query → snapshot cache → optimistic; rollback + refetch
// saat version mismatch/lock/contention; commit respons server lalu invalidate.
function withGranularOptimisticLifecycle<TVars>(
  queryClient: QueryClient,
  sessionId: string,
  optimisticUpdate: (previous: CloudSnapshot, vars: TVars) => CloudSnapshot | undefined,
  invalidate: () => void | Promise<void>,
) {
  return {
    onMutate: async (vars: TVars) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (previous) {
        const next = optimisticUpdate(previous, vars)
        if (next) queryClient.setQueryData(['session', sessionId], next)
      }
      return { previous }
    },
    onError: async (error: unknown, _vars: TVars, ctx: { previous?: CloudSnapshot } | undefined) => {
      if (ctx?.previous !== undefined) queryClient.setQueryData(['session', sessionId], ctx.previous)
      if (isVersionMismatch(error) || isLockedError(error) || isContentionError(error)) {
        try {
          await queryClient.fetchQuery<CloudSnapshot | null>({
            queryKey: ['session', sessionId],
            queryFn: () => getSession(sessionId),
          })
        } catch { /* ignore */ }
      }
    },
    onSuccess: (snap: CloudSnapshot) => {
      queryClient.setQueryData(['session', sessionId], snap)
      void invalidate()
    },
  }
}

// Retry 1x on row-level OCC conflict: fetch game version → patch → ulangi sekali.
async function withGameVersionRetry<T>(
  sessionId: string,
  key: string,
  patch: (version: number) => Promise<T>,
): Promise<T> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const game = await getGame(sessionId, key)
    if (!game) throw new Error(`Game ${key} not found`)
    try {
      return await patch(game.version)
    } catch (err) {
      if (attempt === 0 && isVersionMismatch(err)) continue
      throw err
    }
  }
  throw new Error('unreachable')
}

// Retry 1x on session-level OCC conflict: baca version dari cache → patch →
// saat mismatch refetch fresh lalu ulangi sekali. `requireFreshVersion` = true
// hanya lanjut kalau snapshot fresh punya version (dipakai patchAbsentPlayers).
async function withSnapshotVersionRetry<T>(
  queryClient: QueryClient,
  sessionId: string,
  patch: (version: number) => Promise<T>,
  opts?: { requireFreshVersion?: boolean },
): Promise<T> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
    const ver = current?.version
    if (ver == null) throw new Error('session version not loaded')
    try {
      return await patch(ver)
    } catch (err) {
      if (attempt === 0 && isVersionMismatch(err)) {
        try {
          const fresh = await queryClient.fetchQuery<CloudSnapshot | null>({
            queryKey: ['session', sessionId],
            queryFn: () => getSession(sessionId),
          })
          if (!opts?.requireFreshVersion || fresh?.version != null) continue
        } catch { /* ignore */ }
      }
      throw err
    }
  }
  throw new Error('unreachable')
}

export function useListSessions(options?: { enabled?: boolean }) {
  return useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: ({ signal }) => listSessions({ signal }),
    enabled: options?.enabled ?? true,
  })
}

export function useGetSession(
  sessionId: string | undefined,
  options?: { refetchInterval?: number | false; refetchOnWindowFocus?: boolean },
) {
  return useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: ({ signal }) => getSession(sessionId!, signal),
    enabled: !!sessionId,
    refetchInterval: options?.refetchInterval,
    refetchOnWindowFocus: options?.refetchOnWindowFocus,
  })
}

export function useSessionRealtime(sessionId: string | undefined, enabled = true) {
  const queryClient = useQueryClient()
  const [connected, setConnected] = useState(false)
  const [reconnecting, setReconnecting] = useState(false)

  useEffect(() => {
    if (!sessionId || !enabled) return
    let isReconnection = false

    // __API_BASE_URL__ is injected at build time (vite.config.ts)
    const url = `${__API_BASE_URL__}/sessions/${encodeURIComponent(sessionId)}/watch`
    const es = new EventSource(url)

    es.onopen = () => {
      setConnected(true)
      // Jika tadinya terputus/reconnecting, picu catch-up refetch dari server
      if (isReconnection) {
        queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
      }
      setReconnecting(false)
      isReconnection = false
    }

    es.onmessage = (e) => {
      try {
        const snap = JSON.parse(e.data) as CloudSnapshot
        queryClient.setQueryData(['session', sessionId], snap)
      } catch {
        // ignore malformed
      }
    }

    es.onerror = () => {
      setConnected(false)
      // Browser akan auto-reconnect EventSource — tandai sebagai reconnecting
      setReconnecting(true)
      isReconnection = true
    }

    // Picu catch-up refetch saat browser terhubung kembali ke internet
    const handleOnline = () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    }
    window.addEventListener('online', handleOnline)

    return () => {
      es.close()
      window.removeEventListener('online', handleOnline)
      setConnected(false)
      setReconnecting(false)
    }
  }, [sessionId, enabled, queryClient])

  return { connected, reconnecting }
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
    onSuccess: async (snap) => {
      if (!sessionId) return
      if (snap) {
        queryClient.setQueryData(['session', sessionId], snap)
      }
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
  return useMutation({
    mutationFn: async (vars: { key: string; nextPlayed?: boolean | string[] }) => {
      const v = vars as { key: string; nextPlayed?: boolean | string[] }
      const { key } = v
      let nextPlayed: boolean | undefined
      if (typeof v.nextPlayed === 'boolean') nextPlayed = v.nextPlayed
      else if (Array.isArray(v.nextPlayed)) nextPlayed = (v.nextPlayed as string[]).includes(key)
      if (typeof nextPlayed !== 'boolean') {
        // Legacy toggle caller (tanpa nextPlayed): onMutate sudah set intent absolut
        // ke cache — baca dari sana (bukan invert dari post-mutate cache, yang
        // akan membalik intent karena onMutate sudah mengubahnya).
        const cur = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
        nextPlayed = (cur?.playedGames ?? []).includes(key)
      }
      const resolvedNextPlayed = nextPlayed
      // Granular: fetch game version → PATCH per game (row-level OCC). Retry 1x on version conflict.
      return withGameVersionRetry(sessionId, key, (version) => patchGamePlayed(sessionId, key, resolvedNextPlayed, version))
    },
    ...withGranularOptimisticLifecycle<{ key: string; nextPlayed?: boolean | string[] }>(
      queryClient,
      sessionId,
      (previous, vars) => {
        let nextPlayed: boolean | undefined
        if (typeof vars.nextPlayed === 'boolean') nextPlayed = vars.nextPlayed
        else if (Array.isArray(vars.nextPlayed)) nextPlayed = vars.nextPlayed.includes(vars.key)
        if (typeof nextPlayed !== 'boolean') nextPlayed = !previous.playedGames.includes(vars.key)
        return setPlayedInSnapshot(previous, vars.key, nextPlayed)
      },
      () => invalidateSessionQueries(queryClient),
    ),
  })
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { key: string; a: number; b: number }) => {
      const { key, a, b } = vars
      return withGameVersionRetry(sessionId, key, (version) => patchGameScore(sessionId, key, a, b, version))
    },
    ...withGranularOptimisticLifecycle<{ key: string; a: number; b: number }>(
      queryClient,
      sessionId,
      (previous, vars) => {
        try {
          return setScoreInSnapshot(previous, vars.key, vars.a, vars.b)
        } catch (e) {
          // invalid score/gameKey — rollback nothing, let BE validate
          console.warn('[useSetScore] optimistic update skipped:', e)
          return undefined
        }
      },
      () => invalidateSessionQueries(queryClient),
    ),
  })
}

export function useSwapPlayers(sessionId: string) {
  return useGranularSwap(
    sessionId,
    'player',
    (old, vars) => {
      const { t1, t2 } = vars as { t1: SwapTarget; t2: SwapTarget }
      return swapPlayersInSnapshot(old, t1, t2)
    },
    (vars) => {
      const { t1, t2 } = vars as { t1: SwapTarget; t2: SwapTarget }
      return {
        a: { slot: t1.slot, court: t1.court, team: t1.team, position: t1.index },
        b: { slot: t2.slot, court: t2.court, team: t2.team, position: t2.index },
      }
    },
  )
}

export function useSwapTeams(sessionId: string) {
  return useGranularSwap(
    sessionId,
    'team',
    (old, vars) => {
      const { t1, t2 } = vars as { t1: TeamSwapTarget; t2: TeamSwapTarget }
      return swapTeamsInSnapshot(old, t1, t2)
    },
    (vars) => {
      const { t1, t2 } = vars as { t1: TeamSwapTarget; t2: TeamSwapTarget }
      return {
        a: { slot: t1.slot, court: t1.court, team: t1.team },
        b: { slot: t2.slot, court: t2.court, team: t2.team },
      }
    },
  )
}

export function useSetAbsent(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (vars: { nextAbsent: string[] }) =>
      withSnapshotVersionRetry(
        queryClient,
        sessionId,
        (ver) => patchAbsentPlayers(sessionId, vars.nextAbsent, ver),
        { requireFreshVersion: true },
      ),
    ...withGranularOptimisticLifecycle<{ nextAbsent: string[] }>(
      queryClient,
      sessionId,
      (previous, vars) => setAbsentPlayersInSnapshot(previous, vars.nextAbsent),
      () => invalidateAllQueries(queryClient),
    ),
  })
}

export function useSetGameSkipped(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { key: string; playerIds: string[] }) => {
      const { key, playerIds } = vars
      return withGameVersionRetry(sessionId, key, (version) => patchGameSkipped(sessionId, key, playerIds, version))
    },
    ...withGranularOptimisticLifecycle<{ key: string; playerIds: string[] }>(
      queryClient,
      sessionId,
      (previous, vars) => setSkippedInSnapshot(previous, vars.key, vars.playerIds),
      () => invalidateSessionQueries(queryClient),
    ),
  })
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
  return useGranularSwap(
    sessionId,
    'slot',
    (old, vars) => {
      const { g1, g2 } = vars as { g1: SlotSwapTarget; g2: SlotSwapTarget }
      return swapSlotsInSnapshot(old, g1, g2)
    },
    (vars) => {
      const { g1, g2 } = vars as { g1: SlotSwapTarget; g2: SlotSwapTarget }
      return { a: { slot: g1.slot, court: g1.court }, b: { slot: g2.slot, court: g2.court } }
    },
  )
}

// ── Factory granular swap ────────────────────────────────────────────────────
// Pakai POST /sessions/{id}/swap (session-level OCC). Optimistic pada snapshot
// cache (helper swap*InSnapshot), onSuccess setQueryData dari server (authoritative).
// Retry 1x on 409: refetch fresh → re-apply swap ke state server (bukan optimistic).
function useGranularSwap<TVars = Record<string, unknown>>(
  sessionId: string,
  kind: 'player' | 'team' | 'slot',
  optimisticUpdate: (old: CloudSnapshot, vars: TVars) => CloudSnapshot,
  mapVars: (vars: TVars) => { a: GranularSwapTarget; b: GranularSwapTarget },
) {
  const queryClient = useQueryClient()
  return useMutation<CloudSnapshot, unknown, TVars, { previous?: CloudSnapshot }>({
    mutationFn: async (vars: TVars) => {
      const { a, b } = mapVars(vars)
      return withSnapshotVersionRetry(
        queryClient,
        sessionId,
        (ver) => swapMembers(sessionId, kind, a, b, ver),
      )
    },
    ...withGranularOptimisticLifecycle<TVars>(
      queryClient,
      sessionId,
      (previous, vars) => optimisticUpdate(previous, vars),
      () => {
        void invalidateSessionQueries(queryClient)
        void queryClient.invalidateQueries({ queryKey: ['ratings'] })
      },
    ),
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
  return useOptimisticSessionMutation(
    sessionId,
    (old, vars) => {
      const { target, newName, playerName } = vars as { target: SwapTarget; newName: string; playerName: string }
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
