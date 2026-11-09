// src/hooks/useDebouncedPublish.ts
// Debounced cloud publish hook — batches rapid local changes into a single
// publish request (PUT /sessions/{id}). Handles in-flight mutation serialization
// to prevent HTTP 412 If-Match version conflict on rapid edits, ensuring optimistic
// snapshot updates are queued and processed sequentially.

import { useRef, useEffect, useCallback, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useStore, recordPendingPublish } from '../store'
import { usePublishSession } from '../queries'
import { publishSession, getSession } from '../queries/endpoints'
import { getSaveErrorMessage } from '../queries/errors'
import { communityQueryKey } from '../queries/keys'
import { buildPublishableSessionSnapshot } from '../utils/sessionSnapshot'
import type { CloudSnapshot } from '../queries/types'

type StoreState = ReturnType<typeof useStore.getState>

/**
 * The snapshot a publish would send. The draft's own basis wins over the
 * cache: after a failed publish the cache holds the server's newer version,
 * and using it would retry the same stale draft over the other editor.
 */
function buildSnapshot(state: StoreState, cached?: CloudSnapshot | null): CloudSnapshot {
  const snap = buildPublishableSessionSnapshot({
    session: state.session,
    players: state.players,
    fixMatches: state.fixMatches,
    schedule: state.schedule,
    playedGames: state.playedGames,
    gameScores: state.gameScores,
    existingAbsentPlayers: state.absentPlayers,
  })
  if (state.cloudVersion != null) snap.version = state.cloudVersion
  else if (cached?.version != null) snap.version = cached.version
  return snap
}

export function useDebouncedPublish(
  cloudSessionId: string | null,
  onError?: (message: string) => void,
  onSaved?: () => void,
) {
  const publishTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const publishStartRef = useRef<number | null>(null)
  const inFlightRef = useRef<boolean>(false)
  const pendingDirtyRef = useRef<boolean>(false)
  const failedRef = useRef<boolean>(false)
  const [isPendingQueue, setIsPendingQueue] = useState<boolean>(false)
  // True from the first local edit until the server acknowledges the write.
  // Only then is a tab close safe to allow without a prompt.
  const [isDirty, setIsDirty] = useState<boolean>(false)

  const queryClient = useQueryClient()
  const publish = usePublishSession(cloudSessionId ?? undefined)

  const publishRef = useRef(publish)
  useEffect(() => {
    publishRef.current = publish
  }, [publish])

  // onError disimpan di ref supaya identitas inline dari caller (arrow baru tiap
  // render) tidak membuat effect cleanup berjalan tiap render — bug write-storm.
  const onErrorRef = useRef(onError)
  useEffect(() => {
    onErrorRef.current = onError
  }, [onError])

  // A successful publish is the acknowledgement that clears the wizard's
  // failure banner; nothing else may remove it.
  const onSavedRef = useRef(onSaved)
  useEffect(() => {
    onSavedRef.current = onSaved
  }, [onSaved])

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
    if (state.cloudSessionId !== cloudSessionId) return

    // The draft's own basis wins over the cache. After a failed publish the
    // cache holds the server's newer version; using it here would retry the
    // same stale draft against the new version and overwrite the other editor.
    const cached = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', cloudSessionId))
    const snap = buildSnapshot(state, cached)

    inFlightRef.current = true
    pendingDirtyRef.current = false
    setIsPendingQueue(false)

    publishRef.current.mutate(snap, {
      onSuccess: (updated) => {
        failedRef.current = false
        // The next publish starts from the version this one produced.
        if (useStore.getState().cloudSessionId === cloudSessionId) {
          useStore.getState().setCloudVersion(updated?.version ?? null)
          // A beforeunload marker from a cancelled close is resolved now.
          if (useStore.getState().pendingPublish?.cloudSessionId === cloudSessionId) {
            useStore.getState().setPendingPublish(null)
          }
        }
        onSavedRef.current?.()
      },
      onError: async (err) => {
        // The last edit is still only local: keep the dirty flag so a tab
        // close asks before dropping it.
        failedRef.current = true
        const message = getSaveErrorMessage(err)
        onErrorRef.current?.(message)
        // Record the unconfirmed write. A navigation can unmount the screen
        // (and its toast) before the reviewer sees it, so the next screen
        // reads this record and offers a retry. The helper refuses after
        // expiry, when the draft no longer belongs to this account.
        const state = useStore.getState()
        if (state.cloudSessionId === cloudSessionId) {
          const cached = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', cloudSessionId))
          recordPendingPublish({
            cloudSessionId,
            snapshot: buildSnapshot(state, cached),
            message,
          })
        }
        if (cloudSessionId) {
          try {
            await queryClient.fetchQuery({
              queryKey: communityQueryKey('session', cloudSessionId),
              queryFn: () => getSession(cloudSessionId),
            })
          } catch {
            // Ignore network fail
          }
        }
      },
      onSettled: () => {
        inFlightRef.current = false
        if (pendingDirtyRef.current) {
          pendingDirtyRef.current = false
          setIsPendingQueue(true)
          // Work is still queued, so the close prompt must stay armed.
          setIsDirty(true)
          publishTimerRef.current = setTimeout(() => {
            doPublishRef.current()
          }, 300)
        } else {
          setIsPendingQueue(false)
          if (!failedRef.current) setIsDirty(false)
        }
      },
    })
  }, [cloudSessionId, queryClient])

  useEffect(() => {
    doPublishRef.current = doPublish
  }, [doPublish])

  const publishToCloud = useCallback(() => {
    if (!cloudSessionId) return

    setIsDirty(true)
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

  // A close or reload inside the debounce window drops the pending write. The
  // draft itself is already in the persisted store; this adds the retry record
  // to that same store and asks the browser to prompt before leaving.
  useEffect(() => {
    if (!cloudSessionId || !isDirty) return
    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      const state = useStore.getState()
      if (state.cloudSessionId !== cloudSessionId) return
      const cached = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', cloudSessionId))
      const recorded = recordPendingPublish({
        cloudSessionId,
        snapshot: buildSnapshot(state, cached),
        message: null,
      })
      if (!recorded) return
      event.preventDefault()
      event.returnValue = ''
    }
    window.addEventListener('beforeunload', onBeforeUnload)
    return () => window.removeEventListener('beforeunload', onBeforeUnload)
  }, [cloudSessionId, isDirty, queryClient])

  // Flush pending publish on unmount
  useEffect(() => {
    return () => {
      // Flush juga saat ada perubahan tertunda yang belum terjadwal (edit terakhir
      // terjadi ketika request lain in-flight → hanya pendingDirtyRef yang set,
      // publishTimerRef kosong). Tanpa ini, edit terakhir hilang saat unmount.
      if (publishTimerRef.current || pendingDirtyRef.current) {
        if (publishTimerRef.current) clearTimeout(publishTimerRef.current)
        publishTimerRef.current = null
        if (cloudSessionId) {
          const state = useStore.getState()
          if (state.cloudSessionId === cloudSessionId) {
            const cached = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', cloudSessionId))
            const snap = buildSnapshot(state, cached)
            // A normal navigation must not show "Changes not saved" before the
            // write is even answered, so the record is written only on failure.
            publishSession(cloudSessionId, snap).then((updated) => {
              if (useStore.getState().cloudSessionId === cloudSessionId) {
                useStore.getState().setCloudVersion(updated?.version ?? null)
                if (useStore.getState().pendingPublish?.cloudSessionId === cloudSessionId) {
                  useStore.getState().setPendingPublish(null)
                }
              }
              void queryClient.invalidateQueries({ queryKey: communityQueryKey('session', cloudSessionId) })
            }).catch((err) => {
              const message = getSaveErrorMessage(err)
              // The screen is gone, so an inline banner cannot report this.
              // The record stays in the store for the next screen to retry,
              // unless expiry already detached it from this account.
              recordPendingPublish({ cloudSessionId, snapshot: snap, message })
              onErrorRef.current?.(message)
            })
          }
        }
      }
      publishStartRef.current = null
      inFlightRef.current = false
      pendingDirtyRef.current = false
      failedRef.current = false
    }
  }, [cloudSessionId, queryClient])

  return { publishToCloud, isSaving: publish.isPending || isPendingQueue }
}
