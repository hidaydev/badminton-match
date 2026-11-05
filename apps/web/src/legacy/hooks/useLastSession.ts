import { useCallback, useRef, useState } from 'react'
import type { SessionMeta } from '../queries/types'

const LS_KEY = 'last-visited-session'

function isSessionMeta(v: unknown): v is SessionMeta {
  return typeof v === 'object' && v !== null && typeof (v as Record<string, unknown>).id === 'string'
}

function readStored(): { meta: SessionMeta | null; raw: string | null } {
  try {
    const raw = localStorage.getItem(LS_KEY)
    if (raw === null) return { meta: null, raw: null }
    const parsed: unknown = JSON.parse(raw)
    return { meta: isSessionMeta(parsed) ? parsed : null, raw }
  } catch {
    return { meta: null, raw: null }
  }
}

/**
 * The session this device last opened. `save` is stable and skips the write
 * when the stored value is already the same, so a caller may keep it in an
 * effect dependency list without writing to storage on every render.
 */
export function useLastSession(): {
  lastSession: SessionMeta | null
  save: (meta: SessionMeta) => void
} {
  const [initial] = useState(readStored)
  const written = useRef<string | null>(initial.raw)

  const save = useCallback((meta: SessionMeta) => {
    let serialized: string
    try {
      serialized = JSON.stringify(meta)
    } catch {
      return
    }
    if (serialized === written.current) return
    try {
      localStorage.setItem(LS_KEY, serialized)
      written.current = serialized
    } catch {
      // storage quota — non-critical, ignore
    }
  }, [])

  return { lastSession: initial.meta, save }
}