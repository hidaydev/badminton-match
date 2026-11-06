import { t } from '../../i18n'
import { ApiError } from './endpoints'

/** Check if error is a version mismatch (optimistic concurrency failure). */
export function isVersionMismatch(error: unknown): boolean {
  if (error instanceof ApiError) {
    if (error.status === 412 || error.code === 'STALE_VERSION' || error.code === '40001') {
      return true
    }
  }
  return error instanceof Error && error.message.toLowerCase().includes('version mismatch')
}

/** Check if error is a lock conflict (session already locked). */
export function isLockedError(error: unknown): boolean {
  if (error instanceof ApiError && error.code === 'LOCKED') return true
  return error instanceof Error && error.message.toLowerCase().includes('locked')
}

/** Check if error is a contention (advisory lock / FOR UPDATE NOWAIT / 429). */
export function isContentionError(error: unknown): boolean {
  if (error instanceof ApiError) {
    if (error.status === 429) return true
    if (error.code === '55P03') return true
  }
  if (error instanceof Error) {
    const msg = error.message.toLowerCase()
    if (msg.includes('being updated by another request')) return true
    if (msg.includes('55p03')) return true
  }
  return false
}

export function getSaveErrorMessage(error: unknown): string {
  const fallback = t('session.action.failed')

  if (!(error instanceof Error)) return fallback

  const message = error.message.toLowerCase()
  const code = error instanceof ApiError ? error.code : null

  if (code === 'STALE_VERSION' || code === '40001' || message.includes('version mismatch') || message.includes('changed since if-match')) {
    return t(message.includes('tournament') ? 'session.staleTournament' : 'session.stale')
  }

  // A guard that refuses the write (finalized source, still-approved session)
  // has a precise sentence; hiding it behind "Failed to save" looks like a bug.
  if (code === 'FORBIDDEN' || code === 'CONFLICT') {
    return error.message
  }

  // A rejected field (blank title, bad date, out-of-range slot) names the rule.
  if (code === 'INVALID_BODY' || code === 'INVALID_PATCH' || code === 'INVALID_SESSION') {
    return error.message
  }

  if (code === '55P03' || message.includes('being updated by another request')) {
    return t(message.includes('tournament') ? 'session.contentionTournament' : 'session.contention')
  }

  if (message.includes('unresolved player')) {
    return t('session.unresolvedPlayers', { detail: error.message })
  }

  if (message.includes('duplicate canonical resolution')) {
    return t('session.duplicateResolution')
  }

  if (message.includes('locked')) {
    return t('session.action.locked')
  }

  if (message.includes('scores cannot') || message.includes('scores must') || message.includes('invalid game key') || message.includes('winner must reach') || message.includes('validation failed')) {
    return error.message.replace(/^invalid session state:\s*/i, '')
  }

  return fallback
}

