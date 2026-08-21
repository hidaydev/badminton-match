// src/hooks/useDebouncedPublish.ts
// Debounced cloud publish hook — batches rapid local changes into a single
// publish request (PUT /sessions/{id}).

import { useRef, useEffect, useCallback } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useStore } from '../store'
import { usePublishSession } from '../queries'
import { publishSession } from '../queries/endpoints'
import { getSaveErrorMessage } from '../queries/errors'
import { buildPublishableSessionSnapshot } from '../utils/sessionSnapshot'
import type { CloudSnapshot } from '../queries/types'

export function useDebouncedPublish(
  cloudSessionId: string | null,
  onError?: (message: string) => void,
) {
  const publishTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const publishStartRef = useRef<number | null>(null)
  const queryClient = useQueryClient()
  const publish = usePublishSession(cloudSessionId ?? undefined)

  const publishToCloud = useCallback(() => {
    if (!cloudSessionId) return

    if (publishTimerRef.current) clearTimeout(publishTimerRef.current)

    const now = Date.now()
    if (!publishStartRef.current) publishStartRef.current = now

    const elapsed = now - publishStartRef.current
    const delay = elapsed > 1000 ? 0 : 300

    publishTimerRef.current = setTimeout(() => {
      publishTimerRef.current = null
      publishStartRef.current = null  // Reset so next change starts fresh debounce
      const state = useStore.getState()
      const snap = buildPublishableSessionSnapshot({
        session: state.session,
        players: state.players,
        fixMatches: state.fixMatches,
        schedule: state.schedule,
        playedGames: state.playedGames,
        gameScores: state.gameScores,
        existingAbsentPlayers: state.absentPlayers,
      })
      publish.mutate(snap, {
        onError: (err) => onError?.(getSaveErrorMessage(err)),
      })
    }, delay)
  }, [cloudSessionId, publish, onError])

  // Flush pending publish on unmount
  useEffect(() => {
    return () => {
      if (publishTimerRef.current) {
        clearTimeout(publishTimerRef.current)
        if (cloudSessionId) {
          const state = useStore.getState()
          const snap = buildPublishableSessionSnapshot({
            session: state.session, players: state.players, fixMatches: state.fixMatches,
            schedule: state.schedule, playedGames: state.playedGames, gameScores: state.gameScores,
            existingAbsentPlayers: state.absentPlayers,
          })
          // Include version from query cache for optimistic concurrency
          const cached = queryClient.getQueryData<CloudSnapshot>(['session', cloudSessionId])
          if (cached?.version) snap.version = cached.version
          publishSession(cloudSessionId, snap).then(() => {
            queryClient.invalidateQueries({ queryKey: ['session', cloudSessionId] })
          }).catch((err) => {
            console.warn('Unmount flush failed:', err)
            onError?.(getSaveErrorMessage(err))
          })
        }
      }
      publishStartRef.current = null
    }
  }, [cloudSessionId, queryClient, onError])

  return { publishToCloud, isSaving: publish.isPending }
}
