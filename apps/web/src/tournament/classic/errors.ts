// Maps API failures to the closest existing message key. The tournament
// endpoints answer 412 for a stale If-Match and 400 for invalid content.

import { ApiError } from '../../auth/api'
import type { MessageKey } from '../../i18n'

export function saveErrorKey(error: unknown): MessageKey {
  if (error instanceof ApiError) {
    if (error.status === 412) return 'tournament.error.conflict'
  }
  return 'tournament.error.invalid'
}

export function loadErrorKey(error: unknown): MessageKey {
  if (error instanceof ApiError && error.status === 404) {
    return 'tournaments.error.notFound'
  }
  return 'tournament.error.load'
}
