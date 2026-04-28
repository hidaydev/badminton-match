import { compressToEncodedURIComponent, decompressFromEncodedURIComponent } from 'lz-string'
import type { Player, SessionConfig, ScheduleSlot } from '../store'
import type { GeneratorResult } from '../generator'

export interface SharedSnapshot {
  sessionId: string
  session: SessionConfig
  players: Player[]
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult
}

export function encodeSnapshot(snapshot: SharedSnapshot): string {
  return compressToEncodedURIComponent(JSON.stringify(snapshot))
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

export function buildShareUrl(snapshot: SharedSnapshot): string {
  const hash = encodeSnapshot(snapshot)
  return `${window.location.origin}/view#${hash}`
}
