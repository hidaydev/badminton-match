import { useEffect, useState } from 'react'
import { ApiError } from '../auth/api'
import { fetchRankings } from './api'
import type { RankingsBoard } from './api'

export type RankingsError = 'notFound' | 'failed'

export type RankingsState = {
  board: RankingsBoard | null
  loading: boolean
  error: RankingsError | null
}

type Settled = {
  requestKey: string | null
  board: RankingsBoard | null
  error: RankingsError | null
}

const UNRESOLVED: Settled = { requestKey: null, board: null, error: null }

/**
 * Loads the board for `slug` and the selected `tier`. The tier is part of the
 * request key, so switching the filter never shows the previous rows while the
 * next response is in flight.
 */
export function useRankings(slug: string | null, tier: string | null): RankingsState {
  const requestKey = slug === null ? null : `${slug}\u0000${tier ?? ''}`
  const [settled, setSettled] = useState<Settled>(UNRESOLVED)

  useEffect(() => {
    if (slug === null || requestKey === null) return
    let active = true

    fetchRankings(slug, tier)
      .then((board) => {
        if (active) setSettled({ requestKey, board, error: null })
      })
      .catch((error: unknown) => {
        if (!active) return
        const errorKind: RankingsError =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ requestKey, board: null, error: errorKind })
      })

    return () => {
      active = false
    }
  }, [slug, tier, requestKey])

  const current = requestKey !== null && settled.requestKey === requestKey
  return {
    board: current ? settled.board : null,
    loading: requestKey !== null && !current,
    error: current ? settled.error : null,
  }
}
