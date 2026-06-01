import type { SessionMeta } from '../queries/types'

const LS_KEY = 'last-visited-session'

function isSessionMeta(v: unknown): v is SessionMeta {
  return typeof v === 'object' && v !== null && typeof (v as Record<string, unknown>).id === 'string'
}

export function useLastSession(): {
  lastSession: SessionMeta | null
  save: (meta: SessionMeta) => void
} {
  let lastSession: SessionMeta | null = null
  try {
    const raw = localStorage.getItem(LS_KEY)
    if (raw) {
      const parsed: unknown = JSON.parse(raw)
      if (isSessionMeta(parsed)) lastSession = parsed
    }
  } catch {
    lastSession = null
  }

  function save(meta: SessionMeta) {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify(meta))
    } catch {
      // storage quota — non-critical, ignore
    }
  }

  return { lastSession, save }
}
