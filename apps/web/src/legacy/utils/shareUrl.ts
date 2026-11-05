import { decompressFromEncodedURIComponent } from 'lz-string'
import type { Player, SessionConfig, ScheduleSlot } from '../types'
import type { GeneratorResult } from '../generator'

export interface SharedSnapshot {
  sessionId: string
  session: SessionConfig
  players: Player[]
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult
}

export function decodeSnapshot(hash: string): SharedSnapshot | null {
  try {
    const raw = hash.startsWith('#') ? hash.slice(1) : hash
    if (!raw) return null
    const json = decompressFromEncodedURIComponent(raw)
    if (!json) return null
    const data = JSON.parse(json) as SharedSnapshot
    if (!data.schedule || !data.players || !data.session) return null
    return data
  } catch {
    return null
  }
}
