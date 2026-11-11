import { useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ApiError } from '../auth/api'
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
 * Loads the effective config for `slug`. The slug is part of the query key, so
 * switching communities never shows the previous community's rows while the new
 * request is in flight.
 *
 * The endpoint answers with the settings and the format list together, so this
 * is the one read for both. A second hook asking for the presets would double
 * the request and split one failure into two.
 */
export function useCommunityConfig(slug: string | null): CommunityConfigState {
  const query = useQuery({
    // The slug is the whole key: switching communities starts a new read
    // instead of showing the previous community's rows while it is in flight.
    queryKey: ['communityConfig', slug ?? ''],
    queryFn: () => fetchCommunityConfigBundle(slug ?? ''),
    enabled: slug !== null,
  })

  const bundle = query.data
  // Screens that compute a default date before they read the config see the
  // community's zone from here on instead of assuming Jakarta. The effect runs
  // on a cached answer too, which a fetch-time side effect would miss.
  useEffect(() => {
    if (bundle !== undefined) setActiveTimeZone(communityTimeZone(bundle.config))
  }, [bundle])

  return {
    config: bundle?.config ?? null,
    presets: bundle?.presets ?? [],
    loading: slug !== null && query.isPending,
    error: query.error === null ? null : settleError(query.error),
  }
}

function settleError(error: unknown): CommunityConfigError {
  return error instanceof ApiError && error.status === 404 ? 'notFound' : 'failed'
}
