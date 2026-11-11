import { useState } from 'react'
import { ApiError } from '../auth/api'
import { useAsyncEffect } from '../hooks/useAsyncEffect'
import type { CommunityConfig, ScoringPreset } from './api'
import { fetchCommunityConfigBundle } from './api'
import { DEFAULT_TIME_ZONE, setActiveTimeZone } from '../utils/day'

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
 * The community's timezone from an effective config, falling back to the
 * platform default. Every instant on a community screen is rendered in this
 * zone, so a community that is not on Jakarta time does not see its own rows a
 * day off.
 */
export function communityTimeZone(config: CommunityConfig | null): string {
  const value = config?.['community.default_timezone']?.value
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : DEFAULT_TIME_ZONE
}

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

  useAsyncEffect((scope) => {
    if (slug === null) return

    fetchCommunityConfigBundle(slug)
      .then(({ config, presets }) => {
        if (!scope.live) return
        // Screens that compute a default date before they read the config see
        // the community's zone from here on instead of assuming Jakarta.
        setActiveTimeZone(communityTimeZone(config))
        setSettled({ slug, config, presets, error: null })
      })
      .catch((error: unknown) => {
        if (!scope.live) return
        const errorKind: CommunityConfigError =
          error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
        setSettled({ slug, config: null, presets: [], error: errorKind })
      })
  }, [slug])

  const current = slug !== null && settled.slug === slug
  return {
    config: current ? settled.config : null,
    presets: current ? settled.presets : [],
    loading: slug !== null && !current,
    error: current ? settled.error : null,
  }
}
