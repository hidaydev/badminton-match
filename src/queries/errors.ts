export function getSaveErrorMessage(error: unknown): string {
  const fallback = 'Failed to save, please try again.'

  if (!(error instanceof Error)) return fallback

  const message = error.message.toLowerCase()

  if (message.includes('session version mismatch')) {
    return 'Session changed elsewhere. Reload the page, then try again.'
  }

  if (message.includes('tournament version mismatch')) {
    return 'Tournament changed elsewhere. Reload the page, then try again.'
  }

  if (message.includes('session is being updated by another request')) {
    return 'Session is being updated. Wait a moment, reload, then try again.'
  }

  if (message.includes('tournament is being updated by another request')) {
    return 'Tournament is being updated. Wait a moment, reload, then try again.'
  }

  return fallback
}
