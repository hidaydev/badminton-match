import { useEffect, useState } from 'react'
import { ApiError } from '../auth/api'
import type { CommunityConfig } from './api'
import { fetchCommunityConfig } from './api'

export type CommunityConfigError = 'notFound' | 'failed'

export type CommunityConfigState = {
  config: CommunityConfig | null
  loading: boolean
  error: CommunityConfigError | null
}

type Settled = {
  slug: string | null
  config: CommunityConfig | null
  error: CommunityConfigError | null
}

const UNRESOLVED: Settled = { slug: null, config: null, error: null }

/**
 * Loads the effective config for `slug`. State carries the slug it belongs to,
 * so switching communities never shows the previous community's rows while the
 * new request is in flight.
 */
export function useCommunityConfig(slug: string | null): CommunityConfigState {
  const [settled, setSettled] = useState<Settled>(UNRESOLVED)

  useEffect(() => {
    if (slug === null) return
    let active = true

    fetchCommunityConfig(slug)
      .then((config) => {
        if (active) setSettled({ slug, config, error: null })
      })
      .catch((error: unknown) => {
        if (!active) return
        const errorKind: CommunityConfigError =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ slug, config: null, error: errorKind })
      })

    return () => {
      active = false
    }
  }, [slug])

  const current = slug !== null && settled.slug === slug
  return {
    config: current ? settled.config : null,
    loading: slug !== null && !current,
    error: current ? settled.error : null,
  }
}
