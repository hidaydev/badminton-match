import { useCallback, useEffect, useState } from 'react'
import { ApiError } from '../auth/api'
import { getPlayer, getMyPlayer, listClaims, listPlayers, PLAYER_PAGE } from './api'
import type { Player, PlayerClaim } from './api'

export type PlayersError = 'notFound' | 'failed'

/**
 * The player this account owns, for the home shortcut. A failed read hides the
 * card instead of blocking the page: the shortcut is a convenience.
 */
export function useMyPlayer(slug: string | null): Player | null {
  const [player, setPlayer] = useState<Player | null>(null)

  useEffect(() => {
    if (slug === null) return
    let active = true
    getMyPlayer(slug)
      .then((row) => {
        if (active) setPlayer(row)
      })
      .catch(() => {
        if (active) setPlayer(null)
      })
    return () => {
      active = false
    }
  }, [slug])

  return player
}

function settleError(error: unknown): PlayersError {
  return error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
}

type Page = {
  key: string
  items: Player[]
  /** `null` when the last page was short, so "load more" has nothing to ask for. */
  cursor: string | null
}

/**
 * The player list, searched by name and walked with the keyset cursor the API
 * returns implicitly as the last id. A new query is a new key, so an answer for
 * the previous search never lands in the current one.
 */
export function usePlayers(slug: string | null, query: string): {
  items: Player[] | null
  loading: boolean
  loadingMore: boolean
  error: PlayersError | null
  hasMore: boolean
  loadMore: () => void
  reload: () => void
} {
  const key = slug === null ? null : `${slug}\u0000${query}`
  const [page, setPage] = useState<Page | null>(null)
  const [failure, setFailure] = useState<{ key: string; error: PlayersError } | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [loadingMore, setLoadingMore] = useState(false)

  useEffect(() => {
    if (slug === null || key === null) return
    let active = true

    listPlayers(slug, { q: query, limit: PLAYER_PAGE })
      .then((items) => {
        if (!active) return
        setFailure(null)
        setPage({
          key,
          items,
          cursor: items.length === PLAYER_PAGE ? items[items.length - 1].id : null,
        })
      })
      .catch((problem: unknown) => {
        if (!active) return
        setFailure({ key, error: settleError(problem) })
        setPage(null)
      })

    return () => {
      active = false
    }
  }, [slug, query, key, attempt])

  const current = key !== null && page !== null && page.key === key ? page : null
  const error = key !== null && failure !== null && failure.key === key ? failure.error : null

  const loadMore = useCallback(() => {
    if (slug === null || key === null || current === null) return
    if (current.cursor === null || loadingMore) return
    setLoadingMore(true)
    listPlayers(slug, { q: query, limit: PLAYER_PAGE, cursor: current.cursor })
      .then((items) => {
        setPage((previous) =>
          previous === null || previous.key !== key
            ? previous
            : {
                key,
                items: [...previous.items, ...items],
                cursor:
                  items.length === PLAYER_PAGE ? items[items.length - 1].id : null,
              },
        )
      })
      .catch((problem: unknown) => setFailure({ key, error: settleError(problem) }))
      .finally(() => setLoadingMore(false))
  }, [slug, query, key, current, loadingMore])

  return {
    items: current === null ? null : current.items,
    loading: key !== null && current === null && error === null,
    loadingMore,
    error,
    hasMore: current !== null && current.cursor !== null,
    loadMore,
    reload: () => setAttempt((count) => count + 1),
  }
}

type Settled<T> = { requestKey: string | null; value: T | null; error: PlayersError | null }

function unresolved<T>(): Settled<T> {
  return { requestKey: null, value: null, error: null }
}

/** One player with their claim history; the page re-reads after every write. */
export function usePlayerDetail(
  slug: string | null,
  id: string | null,
): {
  player: Player | null
  claims: PlayerClaim[] | null
  loading: boolean
  error: PlayersError | null
  reload: () => void
} {
  const requestKey = slug === null || id === null ? null : `${slug}\u0000${id}`
  const [player, setPlayer] = useState<Settled<Player>>(unresolved)
  const [claims, setClaims] = useState<Settled<PlayerClaim[]>>(unresolved)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (slug === null || id === null || requestKey === null) return
    let active = true

    getPlayer(slug, id)
      .then((value) => {
        if (active) setPlayer({ requestKey, value, error: null })
      })
      .catch((problem: unknown) => {
        if (active) setPlayer({ requestKey, value: null, error: settleError(problem) })
      })

    listClaims(slug, id)
      .then((value) => {
        if (active) setClaims({ requestKey, value, error: null })
      })
      .catch((problem: unknown) => {
        if (active) setClaims({ requestKey, value: null, error: settleError(problem) })
      })

    return () => {
      active = false
    }
  }, [slug, id, requestKey, attempt])

  const playerCurrent = requestKey !== null && player.requestKey === requestKey
  const claimsCurrent = requestKey !== null && claims.requestKey === requestKey

  return {
    player: playerCurrent ? player.value : null,
    claims: claimsCurrent ? claims.value : null,
    loading: requestKey !== null && !playerCurrent,
    error: playerCurrent ? player.error : null,
    reload: () => setAttempt((count) => count + 1),
  }
}
