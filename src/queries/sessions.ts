import { useCallback, useEffect, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, deleteSession, getGame, patchGameScore, patchGamePlayed, patchAbsentPlayers, patchGameSkipped, swapMembers } from './endpoints'
import type { GranularSwapTarget } from './endpoints'
import type { CloudSnapshot, SessionMeta } from './types'
import { isVersionMismatch, isLockedError, isContentionError } from './errors'
import type { SwapTarget, TeamSwapTarget, ChangeTarget } from '../utils/swap'
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
  ])
}

export function useListSessions(options?: { enabled?: boolean }) {
  return useQuery<SessionMeta[]>({
    queryKey: ['sessions'],
    queryFn: listSessions,
    enabled: options?.enabled ?? true,
  })
}

export function useGetSession(
  sessionId: string | undefined,
  options?: { refetchInterval?: number | false; refetchOnWindowFocus?: boolean },
) {
  return useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
    refetchInterval: options?.refetchInterval as unknown as number | false | undefined,
    refetchOnWindowFocus: options?.refetchOnWindowFocus,
  })
}

export function useSessionRealtime(sessionId: string | undefined, enabled = true) {
  const queryClient = useQueryClient()
  const [connected, setConnected] = useState(false)
  useEffect(() => {
    if (!sessionId || !enabled) return
    // __API_BASE_URL__ is injected at build time (vite.config.ts)
    const url = `${__API_BASE_URL__}/sessions/${encodeURIComponent(sessionId)}/watch`
    const es = new EventSource(url)
    es.onopen = () => setConnected(true)
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
      es.close()
    }
    return () => {
      es.close()
      setConnected(false)
    }
  }, [sessionId, enabled, queryClient])
  return connected
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
      // Granular: fetch game version → PATCH per game (row-level OCC). Retry 1x on version conflict.
      for (let attempt = 0; attempt < 2; attempt++) {
        const game = await getGame(sessionId, key)
        if (!game) throw new Error(`Game ${key} not found`)
        try {
          return await patchGamePlayed(sessionId, key, nextPlayed, game.version)
        } catch (err) {
          if (attempt === 0 && isVersionMismatch(err)) continue
          throw err
        }
      }
      throw new Error('unreachable')
    },
    onMutate: async (vars) => {
      const { key } = vars as { key: string }
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (previous) {
        let nextPlayed: boolean | undefined
        const v = vars as { key: string; nextPlayed?: boolean | string[] }
        if (typeof v.nextPlayed === 'boolean') nextPlayed = v.nextPlayed
        else if (Array.isArray(v.nextPlayed)) nextPlayed = (v.nextPlayed as string[]).includes(key)
        if (typeof nextPlayed !== 'boolean') nextPlayed = !previous.playedGames.includes(key)
        queryClient.setQueryData(['session', sessionId], setPlayedInSnapshot(previous, key, nextPlayed))
      }
      return { previous }
    },
    onError: async (error, _vars, ctx) => {
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
    onSuccess: (snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
      void invalidateSessionQueries(queryClient)
    },
  })
}

export function useSetScore(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { key: string; a: number; b: number }) => {
      const { key, a, b } = vars
      for (let attempt = 0; attempt < 2; attempt++) {
        const game = await getGame(sessionId, key)
        if (!game) throw new Error(`Game ${key} not found`)
        try {
          return await patchGameScore(sessionId, key, a, b, game.version)
        } catch (err) {
          if (attempt === 0 && isVersionMismatch(err)) continue
          throw err
        }
      }
      throw new Error('unreachable')
    },
    onMutate: async (vars) => {
      const { key, a, b } = vars
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (previous) {
        try {
          queryClient.setQueryData(['session', sessionId], setScoreInSnapshot(previous, key, a, b))
        } catch (e) {
          // invalid score/gameKey — rollback nothing, let BE validate
          console.warn('[useSetScore] optimistic update skipped:', e)
        }
      }
      return { previous }
    },
    onError: async (error, _vars, ctx) => {
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
    onSuccess: (snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
      void invalidateSessionQueries(queryClient)
    },
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
    mutationFn: async (vars: { nextAbsent: string[] }) => {
      const { nextAbsent } = vars
      for (let attempt = 0; attempt < 2; attempt++) {
        const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
        const ver = current?.version
        if (ver == null) throw new Error('session version not loaded')
        try {
          return await patchAbsentPlayers(sessionId, nextAbsent, ver)
        } catch (err) {
          if (attempt === 0 && isVersionMismatch(err)) {
            // refetch fresh then retry with new version
            try {
              const fresh = await queryClient.fetchQuery<CloudSnapshot | null>({
                queryKey: ['session', sessionId],
                queryFn: () => getSession(sessionId),
              })
              if (fresh?.version != null) continue
            } catch { /* ignore */ }
          }
          throw err
        }
      }
      throw new Error('unreachable')
    },
    onMutate: async (vars) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (previous) {
        queryClient.setQueryData(['session', sessionId], setAbsentPlayersInSnapshot(previous, (vars as { nextAbsent: string[] }).nextAbsent))
      }
      return { previous }
    },
    onError: async (error, _vars, ctx) => {
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
    onSuccess: (snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
      void invalidateAllQueries(queryClient)
    },
  })
}

export function useSetGameSkipped(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { key: string; playerIds: string[] }) => {
      const { key, playerIds } = vars
      for (let attempt = 0; attempt < 2; attempt++) {
        const game = await getGame(sessionId, key)
        if (!game) throw new Error(`Game ${key} not found`)
        try {
          return await patchGameSkipped(sessionId, key, playerIds, game.version)
        } catch (err) {
          if (attempt === 0 && isVersionMismatch(err)) continue
          throw err
        }
      }
      throw new Error('unreachable')
    },
    onMutate: async (vars) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (previous) {
        queryClient.setQueryData(['session', sessionId], setSkippedInSnapshot(previous, vars.key, vars.playerIds))
      }
      return { previous }
    },
    onError: async (error, _vars, ctx) => {
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
    onSuccess: (snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
      void invalidateSessionQueries(queryClient)
    },
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
      for (let attempt = 0; attempt < 2; attempt++) {
        const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
        const ver = current?.version
        if (ver == null) throw new Error('session version not loaded')
        try {
          return await swapMembers(sessionId, kind, a, b, ver)
        } catch (err) {
          if (attempt === 0 && isVersionMismatch(err)) {
            try {
              await queryClient.fetchQuery<CloudSnapshot | null>({
                queryKey: ['session', sessionId],
                queryFn: () => getSession(sessionId),
              })
              continue
            } catch { /* ignore */ }
          }
          throw err
        }
      }
      throw new Error('unreachable')
    },
    onMutate: async (vars: TVars) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (previous) {
        queryClient.setQueryData(['session', sessionId], optimisticUpdate(previous, vars))
      }
      return { previous }
    },
    onError: async (error, _vars, ctx) => {
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
    onSuccess: (snap) => {
      queryClient.setQueryData(['session', sessionId], snap)
      void invalidateSessionQueries(queryClient)
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
