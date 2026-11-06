import { useCallback, useRef, useState } from 'react'
import type { SessionMeta } from '../queries/types'

const LS_KEY = 'last-visited-session'

/** The session plus the community it belongs to, so its link survives a switch. */
export interface LastSessionMeta extends SessionMeta {
  slug: string
}

function isLastSession(v: unknown): v is LastSessionMeta {
  if (typeof v !== 'object' || v === null) return false
  const row = v as Record<string, unknown>
  // Rows written before the slug was stored are not usable: the legacy router
  // would prefix them with whichever community is open when the card is clicked.
  return typeof row.id === 'string' && typeof row.slug === 'string' && row.slug !== ''
}

function readStored(): { meta: LastSessionMeta | null; raw: string | null } {
  try {
    const raw = localStorage.getItem(LS_KEY)
    if (raw === null) return { meta: null, raw: null }
    const parsed: unknown = JSON.parse(raw)
    return { meta: isLastSession(parsed) ? parsed : null, raw }
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
  lastSession: LastSessionMeta | null
  save: (meta: LastSessionMeta) => void
} {
  const [initial] = useState(readStored)
  const written = useRef<string | null>(initial.raw)

  const save = useCallback((meta: LastSessionMeta) => {
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