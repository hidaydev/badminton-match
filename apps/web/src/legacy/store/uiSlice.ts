import type { SetState } from './index'

export interface UISlice {
  absentPlayers: string[]
  cloudSessionId: string | null

  setAbsentPlayers: (ids: string[]) => void
  setCloudSessionId: (id: string) => void
}

export const createUISlice = (
  set: SetState
): UISlice => ({
  absentPlayers: [],
  cloudSessionId: null,

  setAbsentPlayers: (ids) => set(() => ({ absentPlayers: [...new Set(ids)] })),
  setCloudSessionId: (id) => set(() => ({ cloudSessionId: id })),
})
