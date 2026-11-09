import type { SetState } from './index'
import type { CloudSnapshot } from '../types'

/**
 * A publish that could not be confirmed by the server. It is persisted with
 * the draft so the next screen (or a reload) can retry instead of dropping the
 * last edit silently.
 */
export interface PendingPublish {
  cloudSessionId: string
  snapshot: CloudSnapshot
  /** Mapped save message; `null` on a pre-flight record from beforeunload. */
  message: string | null
  /**
   * When this record was first created, in epoch milliseconds. The age is
   * measured from here, so repeated failures do not extend the window in
   * which the copy may be forced over another editor's work.
   */
  failedAt: number
}

/**
 * The copy may only be forced over a collaborator's version within this
 * window. Older records can only be reloaded, because anything older than
 * half an hour is more likely to be a forgotten draft than a live edit.
 */
export const PENDING_OVERWRITE_WINDOW_MS = 30 * 60 * 1000

export interface UISlice {
  absentPlayers: string[]
  cloudSessionId: string | null
  /**
   * Version of the published session the draft was based on. It is persisted
   * with the draft so a reload can still tell the server "this is what I
   * started from": without it, the first publish after a reload would send the
   * server's current version and overwrite newer scores from another editor.
   */
  cloudVersion: number | null
  /** A write the server never confirmed; survives navigation and reload. */
  pendingPublish: PendingPublish | null

  setAbsentPlayers: (ids: string[]) => void
  setCloudSessionId: (id: string) => void
  setCloudVersion: (version: number | null) => void
  setPendingPublish: (pending: PendingPublish | null) => void
}

export const createUISlice = (
  set: SetState
): UISlice => ({
  absentPlayers: [],
  cloudSessionId: null,
  cloudVersion: null,
  pendingPublish: null,

  setAbsentPlayers: (ids) => set(() => ({ absentPlayers: [...new Set(ids)] })),
  // A new id is a new session, so the old basis cannot describe it.
  setCloudSessionId: (id) =>
    set((s) => ({
      cloudSessionId: id,
      cloudVersion: s.cloudSessionId === id ? s.cloudVersion : null,
      pendingPublish: s.cloudSessionId === id ? s.pendingPublish : null,
    })),
  setCloudVersion: (version) => set(() => ({ cloudVersion: version })),
  setPendingPublish: (pending) => set(() => ({ pendingPublish: pending })),
})
