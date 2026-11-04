import { useCallback, useEffect, useState } from 'react'
import { ApiError } from '../auth/api'
import { getSession, getSessionStandings, listSessions } from './api'
import type { SessionBoard, SessionDetail, SessionMeta } from './api'

export type SessionsError = 'notFound' | 'failed'

type Settled<T> = { requestKey: string | null; value: T | null; error: SessionsError | null }

function unresolved<T>(): Settled<T> {
  return { requestKey: null, value: null, error: null }
}

function settleError(error: unknown): SessionsError {
  return error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
}

function requestKeyFor(...parts: string[]): string {
  return parts.join('\u0000')
}

/**
 * Loads one session, its schedule and its board behind a single request key, so
 * a page never mixes the previous session's games with the next one's header.
 */
export function useSession(
  slug: string | null,
  id: string | null,
): {
  session: SessionDetail | null
  board: SessionBoard | null
  loading: boolean
  error: SessionsError | null
  reload: () => void
} {
  const requestKey = slug === null || id === null ? null : requestKeyFor(slug, id)
  const [session, setSession] = useState<Settled<SessionDetail>>(unresolved)
  const [board, setBoard] = useState<Settled<SessionBoard>>(unresolved)
  const [reloadCount, setReloadCount] = useState(0)
  // Every write bumps the session version, so the page re-reads instead of
  // guessing what the server now holds.
  const reload = useCallback(() => setReloadCount((count) => count + 1), [])

  useEffect(() => {
    if (slug === null || id === null || requestKey === null) return
    let active = true

    getSession(slug, id)
      .then((value) => {
        if (active) setSession({ requestKey, value, error: null })
      })
      .catch((error: unknown) => {
        if (active) setSession({ requestKey, value: null, error: settleError(error) })
      })

    getSessionStandings(slug, id)
      .then((value) => {
        if (active) setBoard({ requestKey, value, error: null })
      })
      .catch((error: unknown) => {
        if (active) setBoard({ requestKey, value: null, error: settleError(error) })
      })

    return () => {
      active = false
    }
  }, [slug, id, requestKey, reloadCount])

  const sessionCurrent = requestKey !== null && session.requestKey === requestKey
  const boardCurrent = requestKey !== null && board.requestKey === requestKey

  return {
    session: sessionCurrent ? session.value : null,
    board: boardCurrent ? board.value : null,
    loading: requestKey !== null && !sessionCurrent,
    error: sessionCurrent ? session.error : null,
    reload,
  }
}

/** The session list for one community. */
export function useSessions(slug: string | null): {
  items: SessionMeta[] | null
  loading: boolean
  error: SessionsError | null
} {
  const [settled, setSettled] = useState<Settled<SessionMeta[]>>(unresolved)

  useEffect(() => {
    if (slug === null) return
    const requestKey = requestKeyFor(slug)
    let active = true

    listSessions(slug)
      .then((value) => {
        if (active) setSettled({ requestKey, value, error: null })
      })
      .catch((error: unknown) => {
        if (active) setSettled({ requestKey, value: null, error: settleError(error) })
      })

    return () => {
      active = false
    }
  }, [slug])

  const current = slug !== null && settled.requestKey === requestKeyFor(slug)
  return {
    items: current ? settled.value : null,
    loading: slug !== null && !current,
    error: current ? settled.error : null,
  }
}
