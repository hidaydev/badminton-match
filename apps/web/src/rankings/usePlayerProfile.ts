import { useEffect, useState } from 'react'
import { ApiError } from '../auth/api'
import { fetchPlayerAchievements, fetchPlayerRow, fetchPlayerStats } from './api'
import type { Achievement, PlayerStats, RankingRow } from './api'

export type PlayerProfile = {
  row: RankingRow
  stats: PlayerStats
  achievements: Achievement[]
}

export type PlayerProfileError = 'notFound' | 'failed'

export type PlayerProfileState = {
  profile: PlayerProfile | null
  loading: boolean
  error: PlayerProfileError | null
}

type Settled = {
  requestKey: string | null
  profile: PlayerProfile | null
  error: PlayerProfileError | null
}

const UNRESOLVED: Settled = { requestKey: null, profile: null, error: null }

/** Row, career stats and badges for one player, resolved together. */
export function usePlayerProfile(
  slug: string | null,
  playerId: string | null,
): PlayerProfileState {
  const requestKey =
    slug === null || playerId === null ? null : `${slug}\u0000${playerId}`
  const [settled, setSettled] = useState<Settled>(UNRESOLVED)

  useEffect(() => {
    if (slug === null || playerId === null || requestKey === null) return
    let active = true

    Promise.all([
      fetchPlayerRow(slug, playerId),
      fetchPlayerStats(slug, playerId),
      fetchPlayerAchievements(slug, playerId),
    ])
      .then(([row, stats, achievements]) => {
        if (active) setSettled({ requestKey, profile: { row, stats, achievements }, error: null })
      })
      .catch((error: unknown) => {
        if (!active) return
        const errorKind: PlayerProfileError =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ requestKey, profile: null, error: errorKind })
      })

    return () => {
      active = false
    }
  }, [slug, playerId, requestKey])

  const current = requestKey !== null && settled.requestKey === requestKey
  return {
    profile: current ? settled.profile : null,
    loading: requestKey !== null && !current,
    error: current ? settled.error : null,
  }
}
