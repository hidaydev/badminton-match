// src/queries/useOptimisticMutation.ts
// Factory hook for session mutations with optimistic updates.
// Eliminates the repeated onMutate/onError/onSuccess boilerplate.

import { useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession } from './endpoints'
import type { CloudSnapshot } from './types'
import { isVersionMismatch } from './errors'

/**
 * Create a mutation hook that:
 * 1. Applies an optimistic update in onMutate
 * 2. Publishes the full snapshot via publishSession
 * 3. Rolls back on error (with version-mismatch refetch)
 * 4. Refetches from server on success
 *
 * @param sessionId - The session ID to mutate
 * @param optimisticUpdate - Function that takes the current snapshot and returns the optimistic version
 * @param onSuccessCallback - Optional callback after successful publish (e.g., for extra invalidation)
 */
export function useOptimisticSessionMutation(
  sessionId: string,
  optimisticUpdate: (old: CloudSnapshot, vars: unknown) => CloudSnapshot,
  onSuccessCallback?: () => Promise<void>,
) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (_vars: unknown) => {
      void _vars // published from cache, vars used only in onMutate
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      return await publishSession(sessionId, current)
    },
    onMutate: async (vars) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        return optimisticUpdate(old, vars)
      })
      return { previous }
    },
    onError: async (_err, _vars, context) => {
      if (context?.previous !== undefined) {
        queryClient.setQueryData(['session', sessionId], context.previous)
      }
      if (isVersionMismatch(_err)) {
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
    onSuccess: async () => {
      await queryClient.fetchQuery<CloudSnapshot | null>({
        queryKey: ['session', sessionId],
        queryFn: () => getSession(sessionId),
      })
      if (onSuccessCallback) await onSuccessCallback()
    },
  })
}
