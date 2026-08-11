// src/queries/useOptimisticMutation.ts
// Factory hook untuk mutations dengan optimistic updates — generik untuk
// session & tournament (dua-duanya pakai pola: read cache → optimistic set →
// publish snapshot → refetch/invalidate → rollback + version-mismatch refetch).

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, getTournament, publishTournament } from './endpoints'
import type { CloudSnapshot, TournamentSnapshot } from './types'
import { isVersionMismatch } from './errors'

/** Snapshot yang di-publish — session atau tournament. */
export type Snapshot = CloudSnapshot | TournamentSnapshot

interface OptimisticMutationOptions<TData extends Snapshot, TVars> {
  /** Query key snapshot (['session', id] atau ['tournament', id]). */
  queryKey: readonly unknown[]
  /**
   * Ambil snapshot terbaru dari server.
   * Dipakai untuk onSuccess refetch & version-mismatch refetch.
   */
  fetchSnapshot: (id: string) => Promise<TData | null>
  /** Publish snapshot ke server. */
  publish: (id: string, snap: TData) => Promise<TData>
  /**
   * Optimistic update — terima snapshot cache + vars, kembalikan versi optimis.
   * Bisa juga MEMBANGUN snapshot baru dari vars (mode "build") — dalam hal ini
   * snapshot cache dipakai hanya untuk ambil version.
   *
   * Set `applyOptimistic` ke false untuk mutasi non-deterministik (mis. random
   * shuffle) — onMutate hanya cancel query, tanpa setQueryData; throw di sini
   * hanya terjadi di mutationFn (bersih).
   */
  optimisticUpdate: (old: TData | null, vars: TVars) => TData | null
  /** Default true. false = tanpa optimistic set (hanya cancel + publish). */
  applyOptimistic?: boolean
  /** Optional callback setelah publish sukses (mis. invalidasi extra). */
  onSuccessCallback?: () => Promise<void>
}

/**
 * Generic optimistic mutation factory.
 *
 * Alur:
 *  1. onMutate: cancel query → simpan previous → set optimistic update
 *  2. mutationFn: publish snapshot dari cache (membawa version → race-safe)
 *  3. onError: rollback → kalau version mismatch, refetch dari server
 *  4. onSuccess: refetch dari server (bukan setQueryData — hindari race)
 *
 * Catatan TOCTOU: semua publish memakai snapshot dari CACHE yang membawa
 * `version` fetch terakhir — dicek server (40001). Jangan pernah publish
 * hasil fresh-get terpisah (open race window).
 */
export function useOptimisticMutation<TData extends Snapshot, TVars = unknown>(
  id: string,
  options: OptimisticMutationOptions<TData, TVars>,
) {
  const queryClient = useQueryClient()
  const { queryKey, fetchSnapshot, publish, optimisticUpdate, applyOptimistic = true, onSuccessCallback } = options

  return useMutation({
    mutationFn: async (vars: TVars) => {
      const current = queryClient.getQueryData<TData>(queryKey)
      const next = optimisticUpdate(current ?? null, vars)
      if (!next) throw new Error('no data')
      return await publish(id, next)
    },
    onMutate: async (vars) => {
      await queryClient.cancelQueries({ queryKey })
      const previous = queryClient.getQueryData<TData>(queryKey)
      if (applyOptimistic) {
        queryClient.setQueryData<TData | null>(queryKey, (old) => optimisticUpdate(old ?? null, vars))
      }
      return { previous }
    },
    onError: async (_err, _vars, context) => {
      if (context?.previous !== undefined) {
        queryClient.setQueryData(queryKey, context.previous)
      }
      if (isVersionMismatch(_err)) {
        try {
          await queryClient.fetchQuery<TData | null>({
            queryKey,
            queryFn: () => fetchSnapshot(id),
          })
        } catch {
          // ignore — stale cache is better than nothing
        }
      }
    },
    onSuccess: async () => {
      // Don't set cache from server response — it can race with subsequent
      // mutations. Instead, refetch fresh data from server.
      await queryClient.fetchQuery<TData | null>({
        queryKey,
        queryFn: () => fetchSnapshot(id),
      })
      if (onSuccessCallback) await onSuccessCallback()
    },
  })
}

// ── Session-specific wrapper (backward compatible) ─────────────────────────
// Mempertahankan API useOptimisticSessionMutation yang sudah dipakai banyak hook.

export function useOptimisticSessionMutation(
  sessionId: string,
  optimisticUpdate: (old: CloudSnapshot, vars: unknown) => CloudSnapshot,
  onSuccessCallback?: () => Promise<void>,
) {
  return useOptimisticMutation<CloudSnapshot, unknown>(
    sessionId,
    {
      queryKey: ['session', sessionId],
      fetchSnapshot: (id) => getSession(id),
      publish: (id, snap) => publishSession(id, snap),
      optimisticUpdate: (old, vars) => {
        if (!old) throw new Error('no data')
        return optimisticUpdate(old, vars)
      },
      onSuccessCallback,
    },
  )
}

// ── Tournament-specific wrapper ────────────────────────────────────────────

export function useOptimisticTournamentMutation<TVars = unknown>(
  tournamentId: string,
  optimisticUpdate: (old: TournamentSnapshot | null, vars: TVars) => TournamentSnapshot | null,
  onSuccessCallback?: () => Promise<void>,
  applyOptimistic = true,
) {
  return useOptimisticMutation<TournamentSnapshot, TVars>(
    tournamentId,
    {
      queryKey: ['tournament', tournamentId],
      fetchSnapshot: (id) => getTournament(id),
      publish: (id, snap) => publishTournament(id, snap),
      optimisticUpdate,
      onSuccessCallback,
      applyOptimistic,
    },
  )
}
