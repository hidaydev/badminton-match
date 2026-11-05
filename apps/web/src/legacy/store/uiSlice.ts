import type { SetState } from './index'

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

  setAbsentPlayers: (ids: string[]) => void
  setCloudSessionId: (id: string) => void
  setCloudVersion: (version: number | null) => void
}

export const createUISlice = (
  set: SetState
): UISlice => ({
  absentPlayers: [],
  cloudSessionId: null,
  cloudVersion: null,

  setAbsentPlayers: (ids) => set(() => ({ absentPlayers: [...new Set(ids)] })),
  // A new id is a new session, so the old basis cannot describe it.
  setCloudSessionId: (id) =>
    set((s) => ({
      cloudSessionId: id,
      cloudVersion: s.cloudSessionId === id ? s.cloudVersion : null,
    })),
  setCloudVersion: (version) => set(() => ({ cloudVersion: version })),
})
