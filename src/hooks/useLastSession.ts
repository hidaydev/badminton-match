import type { SessionMeta } from '../queries/types'

const LS_KEY = 'last-visited-session'

export function useLastSession(): {
  lastSession: SessionMeta | null
  save: (meta: SessionMeta) => void
} {
  let lastSession: SessionMeta | null = null
  try {
    const raw = localStorage.getItem(LS_KEY)
    if (raw) lastSession = JSON.parse(raw) as SessionMeta
  } catch {
    lastSession = null
  }

  function save(meta: SessionMeta) {
    localStorage.setItem(LS_KEY, JSON.stringify(meta))
  }

  return { lastSession, save }
}
