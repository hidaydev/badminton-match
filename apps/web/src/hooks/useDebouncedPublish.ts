// src/hooks/useDebouncedPublish.ts
// Debounced cloud publish hook — batches rapid local changes into a single
// publish request (PUT /sessions/{id}). Handles in-flight mutation serialization
// to prevent HTTP 412 If-Match version conflict on rapid edits, ensuring optimistic
// snapshot updates are queued and processed sequentially.

import { useRef, useEffect, useCallback, useState } from 'react'
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
  const inFlightRef = useRef<boolean>(false)
  const pendingDirtyRef = useRef<boolean>(false)
  const [isPendingQueue, setIsPendingQueue] = useState<boolean>(false)

  const queryClient = useQueryClient()
  const publish = usePublishSession(cloudSessionId ?? undefined)

  const publishRef = useRef(publish)
  useEffect(() => {
    publishRef.current = publish
  }, [publish])

  const doPublishRef = useRef<() => void>(() => {})

  const doPublish = useCallback(() => {
    if (!cloudSessionId || inFlightRef.current) {
      if (inFlightRef.current) {
        pendingDirtyRef.current = true
        setIsPendingQueue(true)
      }
      return
    }

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

    const cached = queryClient.getQueryData<CloudSnapshot>(['session', cloudSessionId])
    if (cached?.version != null) snap.version = cached.version

    inFlightRef.current = true
    pendingDirtyRef.current = false
    setIsPendingQueue(false)

    publishRef.current.mutate(snap, {
      onError: (err) => onError?.(getSaveErrorMessage(err)),
      onSettled: () => {
        inFlightRef.current = false
        if (pendingDirtyRef.current) {
          pendingDirtyRef.current = false
          setIsPendingQueue(true)
          publishTimerRef.current = setTimeout(() => {
            doPublishRef.current()
          }, 300)
        } else {
          setIsPendingQueue(false)
        }
      },
    })
  }, [cloudSessionId, onError, queryClient])

  useEffect(() => {
    doPublishRef.current = doPublish
  }, [doPublish])

  const publishToCloud = useCallback(() => {
    if (!cloudSessionId) return

    if (publishTimerRef.current) clearTimeout(publishTimerRef.current)

    if (inFlightRef.current) {
      pendingDirtyRef.current = true
      setIsPendingQueue(true)
      return
    }

    const now = Date.now()
    if (!publishStartRef.current) publishStartRef.current = now

    const elapsed = now - publishStartRef.current
    const delay = elapsed > 1000 ? 0 : 300

    publishTimerRef.current = setTimeout(() => {
      publishTimerRef.current = null
      publishStartRef.current = null
      doPublish()
    }, delay)
  }, [cloudSessionId, doPublish])

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
          const cached = queryClient.getQueryData<CloudSnapshot>(['session', cloudSessionId])
          if (cached?.version != null) snap.version = cached.version
          publishSession(cloudSessionId, snap).then(() => {
            queryClient.invalidateQueries({ queryKey: ['session', cloudSessionId] })
          }).catch((err) => {
            console.warn('Unmount flush failed:', err)
            onError?.(getSaveErrorMessage(err))
          })
        }
      }
      publishStartRef.current = null
      inFlightRef.current = false
      pendingDirtyRef.current = false
    }
  }, [cloudSessionId, queryClient, onError])

  return { publishToCloud, isSaving: publish.isPending || isPendingQueue }
}
