import { useCallback, useEffect, useRef, useState } from 'react'
import { useQuery, useInfiniteQuery, useMutation, useQueryClient, keepPreviousData } from '@tanstack/react-query'
import type { QueryClient } from '@tanstack/react-query'
import { getSession, publishSession, listSessions, setSessionLock, patchGameScore, patchGamePlayed, patchAbsentPlayers, patchGameSkipped, swapMembers, issueSessionTicket, activeCommunitySlug } from './endpoints'
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
import { communityQueryKey } from './keys'

async function invalidateSessionQueries(queryClient: ReturnType<typeof useQueryClient>) {
  await queryClient.invalidateQueries({ queryKey: communityQueryKey('sessions') })
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
      await queryClient.cancelQueries({ queryKey: communityQueryKey('session', sessionId) })
      const previous = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', sessionId))
      if (previous) {
        const next = optimisticUpdate(previous, vars)
        if (next) queryClient.setQueryData(communityQueryKey('session', sessionId), next)
      }
      return { previous }
    },
    onError: async (error: unknown, _vars: TVars, ctx: { previous?: CloudSnapshot } | undefined) => {
      if (ctx?.previous !== undefined) queryClient.setQueryData(communityQueryKey('session', sessionId), ctx.previous)
      if (isVersionMismatch(error) || isLockedError(error) || isContentionError(error)) {
        try {
          await queryClient.fetchQuery<CloudSnapshot | null>({
            queryKey: communityQueryKey('session', sessionId),
            queryFn: () => getSession(sessionId),
          })
        } catch { /* ignore */ }
      }
    },
    onSuccess: (snap: CloudSnapshot) => {
      queryClient.setQueryData(communityQueryKey('session', sessionId), snap)
      void invalidate()
    },
  }
}

// Every game write carries the session version, and the cached snapshot always
// holds it, so a game edit does not re-read the whole session to learn the
// number (FE-31). A stale cache still costs one refetch inside the retry.

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
    const current = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', sessionId))
    const ver = current?.version
    if (ver == null) throw new Error('session version not loaded')
    try {
      return await patch(ver)
    } catch (err) {
      if (attempt === 0 && isVersionMismatch(err)) {
        try {
          const fresh = await queryClient.fetchQuery<CloudSnapshot | null>({
            queryKey: communityQueryKey('session', sessionId),
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

const SESSION_PAGE_SIZE = 100

/**
 * The list inputs are typed one key at a time. Feeding each keystroke straight
 * into the query key would leave one cache entry per prefix, so changes settle
 * first; the value present on mount is used immediately, so opening the page
 * never waits.
 */
function useSettledValue<T>(value: T, delayMs = 300): T {
  const [settled, setSettled] = useState(value)
  const initial = useRef(value)

  useEffect(() => {
    if (Object.is(value, initial.current)) {
      setSettled(value)
      return
    }
    const timer = setTimeout(() => setSettled(value), delayMs)
    return () => clearTimeout(timer)
  }, [value, delayMs])

  return settled
}

export function useListSessions(options?: {
  date?: string
  q?: string
  limit?: number
  enabled?: boolean
}) {
  const date = useSettledValue(options?.date)
  const q = useSettledValue(options?.q)
  const query = useInfiniteQuery({
    queryKey: communityQueryKey('sessions', date, q, options?.limit),
    queryFn: ({ pageParam, signal }) =>
      listSessions({
        date,
        q,
        limit: options?.limit ?? SESSION_PAGE_SIZE,
        offset: pageParam,
        signal,
      }),
    initialPageParam: 0,
    getNextPageParam: (last) => last.nextOffset,
    enabled: options?.enabled ?? true,
    // Keep the rows on screen while a new filter resolves instead of blanking
    // the list back to its skeleton.
    placeholderData: keepPreviousData,
  })

  const sessions: SessionMeta[] = query.data?.pages.flatMap((page) => page.items) ?? []
  // `total` is the server's count for the current filter, not the loaded slice:
  // the header must not claim "12 total" because only 12 arrived.
  const total = query.data?.pages[0]?.total ?? sessions.length

  return {
    ...query,
    data: sessions,
    total,
    hasMore: query.hasNextPage,
    loadMore: query.fetchNextPage,
    isLoadingMore: query.isFetchingNextPage,
  }
}

/**
 * One server page of sessions at a known offset. The admin table needs random
 * access to any page, which an infinite query cannot give without loading the
 * pages in between; the list endpoint already takes `limit`/`offset`.
 */
export function useSessionPage(page: number, limit = SESSION_PAGE_SIZE) {
  const query = useQuery({
    queryKey: communityQueryKey('sessions', 'page', page, limit),
    queryFn: ({ signal }) =>
      listSessions({ limit, offset: page * limit, signal }),
    // Keep the current rows visible while the next page arrives.
    placeholderData: keepPreviousData,
  })

  return {
    ...query,
    data: query.data?.items ?? [],
    total: query.data?.total ?? 0,
  }
}

export function useSetSessionLock(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ locked, version }: { locked: boolean; version: number }) =>
      setSessionLock(sessionId, locked, version),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: communityQueryKey('session', sessionId) })
      queryClient.invalidateQueries({ queryKey: communityQueryKey('sessions') })
    },
  })
}

export function useGetSession(
  sessionId: string | undefined,
  options?: { refetchInterval?: number | false; refetchOnWindowFocus?: boolean },
) {
  const queryClient = useQueryClient()
  const queryKey = communityQueryKey('session', sessionId)
  return useQuery<CloudSnapshot | null>({
    queryKey,
    // The poll asks the API "still version N?" and keeps the cached snapshot on
    // a 304, so a five-second interval does not re-download and re-render the
    // whole session when nothing changed.
    queryFn: ({ signal }) =>
      getSession(sessionId!, signal, () =>
        queryClient.getQueryData<CloudSnapshot | null>(queryKey),
      ),
    enabled: !!sessionId,
    refetchInterval: options?.refetchInterval,
    refetchOnWindowFocus: options?.refetchOnWindowFocus,
  })
}

/** The server answers `{"type":"ping"}` with `{"type":"pong"}`. */
const PING_MS = 25_000

/**
 * v1 streamed snapshots over SSE. v2 publishes `session.changed` on a
 * WebSocket; the page keeps its 5s refetch while this reports
 * `connected: false`, so a dropped socket degrades instead of breaking.
 *
 * The socket stays open for the whole page visit: closing it on every save
 * would burn a ticket and drop `session.changed` frames from other editors.
 * The server has no replay buffer, so the first open after a reconnect
 * refetches the snapshot once to catch up with what was missed.
 *
 * The URL is built from `VITE_WS_BASE` (or the API base when that is absolute),
 * because in production the socket lives on the API origin: a Vercel rewrite
 * cannot carry an upgrade.
 */
export function useSessionRealtime(sessionId: string | undefined, enabled = true) {
  const queryClient = useQueryClient()
  const [connected, setConnected] = useState(false)
  const [reconnecting, setReconnecting] = useState(false)

  useEffect(() => {
    // The cleanup below already resets the flags, so a disabled hook is a no-op.
    if (!sessionId || !enabled) return
    let active = true
    let socket: WebSocket | null = null
    let timer: ReturnType<typeof setTimeout> | null = null
    let pingTimer: ReturnType<typeof setInterval> | null = null
    let attempt = 0
    let opened = false

    const stopPing = () => {
      if (pingTimer !== null) {
        clearInterval(pingTimer)
        pingTimer = null
      }
    }

    const send = (frame: Record<string, unknown>) => {
      // Anything but `ping`/`subscribe` makes the server drop the socket.
      if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(frame))
    }

    const retry = () => {
      if (!active) return
      setReconnecting(true)
      const delay = Math.min(30_000, 1_000 * 2 ** attempt)
      attempt += 1
      timer = setTimeout(() => { void connect() }, delay)
    }

    const connect = async () => {
      try {
        const { ticket } = await issueSessionTicket(sessionId)
        if (!active) return
        const slug = activeCommunitySlug()
        socket = new WebSocket(
          `${socketBase()}/ws/c/${encodeURIComponent(slug)}` +
          `/sessions/${encodeURIComponent(sessionId)}` +
          `?ticket=${encodeURIComponent(ticket)}`,
        )
        socket.onopen = () => {
          attempt = 0
          setConnected(true)
          setReconnecting(false)
          send({ type: 'subscribe', lastSeq: 0 })
          // Deltas published while the socket was down are gone for good, so a
          // reconnect needs one refetch. The very first open rides the fetch
          // the page already issued on mount.
          if (opened) {
            void queryClient.invalidateQueries({ queryKey: communityQueryKey('session', sessionId) })
          }
          opened = true
          stopPing()
          pingTimer = setInterval(() => send({ type: 'ping' }), PING_MS)
        }
        socket.onmessage = (event) => {
          let frame: { type?: string; seq?: number }
          try {
            frame = JSON.parse(String(event.data)) as { type?: string; seq?: number }
          } catch {
            return
          }
          if (frame.type === 'session.changed') {
            // `seq` is the session version that produced the frame. Our own
            // write already brought that version into the cache, so the echo
            // must not fetch the whole snapshot a second time.
            const cached = queryClient.getQueryData<CloudSnapshot>(
              communityQueryKey('session', sessionId),
            )
            if (
              typeof frame.seq === 'number' &&
              cached?.version != null &&
              cached.version >= frame.seq
            ) {
              return
            }
            void queryClient.invalidateQueries({ queryKey: communityQueryKey('session', sessionId) })
          }
          if (frame.type === 'full' || frame.type === 'revoked') {
            // The link is gone or this process is full; stop reconnecting and
            // let the polling path keep the screen correct.
            active = false
            stopPing()
            socket?.close()
          }
        }
        socket.onclose = () => {
          stopPing()
          setConnected(false)
          retry()
        }
        socket.onerror = () => socket?.close()
      } catch {
        retry()
      }
    }

    void connect()
    return () => {
      active = false
      if (timer !== null) clearTimeout(timer)
      stopPing()
      socket?.close()
      setConnected(false)
      setReconnecting(false)
    }
  }, [sessionId, enabled, queryClient])

  return { connected, reconnecting }
}

function socketBase(): string {
  const configured = import.meta.env.VITE_WS_BASE as string | undefined
  if (configured) return configured.replace(/\/+$/, '')
  const api = import.meta.env.VITE_API_BASE as string | undefined
  if (api && /^https?:/.test(api)) return api.replace(/^http/, 'ws').replace(/\/+$/, '')
  const scheme = window.location.protocol === 'https:' ? 'wss' : 'ws'
  return `${scheme}://${window.location.host}`
}

export function usePublishSession(sessionId: string | undefined) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (snap: CloudSnapshot) => {
      const current = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', sessionId))
      const next: CloudSnapshot = {
        ...snap,
        version: snap.version ?? current?.version,
        absentPlayers: snap.absentPlayers ?? current?.absentPlayers,
      }
      return publishSession(sessionId!, next)
    },
    onMutate: async () => {
      if (!sessionId) return undefined
      await queryClient.cancelQueries({ queryKey: communityQueryKey('session', sessionId) })
      const previous = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', sessionId))
      return { previous }
    },
    onSuccess: async (snap) => {
      if (!sessionId) return
      if (snap) {
        queryClient.setQueryData(communityQueryKey('session', sessionId), snap)
      }
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: communityQueryKey('session', sessionId),
        queryFn: () => getSession(sessionId),
      })
      await invalidateSessionQueries(queryClient)
    },
    onError: async (error, _vars, context) => {
      if (!sessionId) return
      // Rollback to previous snapshot
      if (context?.previous !== undefined) {
        queryClient.setQueryData(communityQueryKey('session', sessionId), context.previous)
      }
      // On version mismatch, refetch the latest snapshot so the user can retry
      // without manually reloading the page.
      if (isVersionMismatch(error)) {
        try {
          await queryClient.fetchQuery<CloudSnapshot | null>({
            queryKey: communityQueryKey('session', sessionId),
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
        const cur = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', sessionId))
        nextPlayed = (cur?.playedGames ?? []).includes(key)
      }
      const resolvedNextPlayed = nextPlayed
      // Granular: PATCH per game with the session version from the cache.
      return withSnapshotVersionRetry(
        queryClient,
        sessionId,
        (version) => patchGamePlayed(sessionId, key, resolvedNextPlayed, version),
      )
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
      return withSnapshotVersionRetry(
        queryClient,
        sessionId,
        (version) => patchGameScore(sessionId, key, a, b, version),
      )
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
      () => invalidateSessionQueries(queryClient),
    ),
  })
}

export function useSetGameSkipped(sessionId: string) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: async (vars: { key: string; playerIds: string[] }) => {
      const { key, playerIds } = vars
      return withSnapshotVersionRetry(
        queryClient,
        sessionId,
        (version) => patchGameSkipped(sessionId, key, playerIds, version),
      )
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
    () => invalidateSessionQueries(queryClient),
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
        void queryClient.invalidateQueries({ queryKey: communityQueryKey('ratings') })
      },
    ),
  })
}

export function useFetchSession() {
  const queryClient = useQueryClient()
  return useCallback(
    (id: string) =>
      queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: communityQueryKey('session', id),
        queryFn: () => getSession(id),
      }),
    [queryClient],
  )
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
    () => invalidateSessionQueries(queryClient),
  )
}
