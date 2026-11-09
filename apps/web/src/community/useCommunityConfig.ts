import { useEffect, useState } from 'react'
import { ApiError } from '../auth/api'
import type { CommunityConfig, ScoringPreset } from './api'
import { fetchCommunityConfigBundle } from './api'

export type CommunityConfigError = 'notFound' | 'failed'

export type CommunityConfigState = {
  config: CommunityConfig | null
  /** The platform's selectable formats, from the same response as `config`. */
  presets: ScoringPreset[]
  loading: boolean
  error: CommunityConfigError | null
}

type Settled = {
  slug: string | null
  config: CommunityConfig | null
  presets: ScoringPreset[]
  error: CommunityConfigError | null
}

const UNRESOLVED: Settled = { slug: null, config: null, presets: [], error: null }

/**
 * Loads the effective config for `slug`. State carries the slug it belongs to,
 * so switching communities never shows the previous community's rows while the
 * new request is in flight.
 *
 * The endpoint answers with the settings and the format list together, so this
 * is the one read for both. A second hook asking for the presets would double
 * the request and split one failure into two.
 */
export function useCommunityConfig(slug: string | null): CommunityConfigState {
  const [settled, setSettled] = useState<Settled>(UNRESOLVED)

  useEffect(() => {
    if (slug === null) return
    let active = true

    fetchCommunityConfigBundle(slug)
      .then(({ config, presets }) => {
        if (active) setSettled({ slug, config, presets, error: null })
      })
      .catch((error: unknown) => {
        if (!active) return
        const errorKind: CommunityConfigError =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ slug, config: null, presets: [], error: errorKind })
      })

    return () => {
      active = false
    }
  }, [slug])

  const current = slug !== null && settled.slug === slug
  return {
    config: current ? settled.config : null,
    presets: current ? settled.presets : [],
    loading: slug !== null && !current,
    error: current ? settled.error : null,
  }
}
