import { ApiError } from './endpoints'

/** Check if error is a version mismatch (optimistic concurrency failure). */
export function isVersionMismatch(error: unknown): boolean {
  return (
    (error instanceof ApiError && error.code === '40001') ||
    (error instanceof Error && error.message.toLowerCase().includes('version mismatch'))
  )
}

/** Check if error is a lock conflict (session already locked). */
export function isLockedError(error: unknown): boolean {
  return (
    error instanceof Error && error.message.toLowerCase().includes('locked')
  )
}

export function getSaveErrorMessage(error: unknown): string {
  const fallback = 'Failed to save, please try again.'

  if (!(error instanceof Error)) return fallback

  const message = error.message.toLowerCase()
  const code = error instanceof ApiError ? error.code : null

  if (code === '40001' || message.includes('version mismatch')) {
    if (message.includes('tournament')) {
      return 'Tournament changed elsewhere. Reload the page, then try again.'
    }
    return 'Session changed elsewhere. Reload the page, then try again.'
  }

  if (code === '55P03' || message.includes('being updated by another request')) {
    if (message.includes('tournament')) {
      return 'Tournament is being updated. Wait a moment, reload, then try again.'
    }
    return 'Session is being updated. Wait a moment, reload, then try again.'
  }

  if (message.includes('unresolved player')) {
    const detail = error.message
    return `Some player names are not recognized: ${detail}`
  }

  if (message.includes('duplicate canonical resolution')) {
    return 'Two different names resolved to the same player. Check for duplicates.'
  }

  if (message.includes('locked')) {
    return 'Session is locked — no further edits allowed.'
  }

  return fallback
}
