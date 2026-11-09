import { readStoredValue } from './storage'

export const MATCH_KEYS = ['score-red', 'score-blue', 'name-red', 'name-blue'] as const

export type MatchKey = (typeof MATCH_KEYS)[number]
export type MatchSnapshot = Record<MatchKey, string>
export type ExportResult = 'shared' | 'copied' | 'cancelled' | 'failed'

const DEFAULTS: MatchSnapshot = {
  'score-red': '0',
  'score-blue': '0',
  'name-red': '',
  'name-blue': '',
}

// The four keys the scoreboard already persists, in one place, so an export
// cannot drift from the storage contract.
export function readMatchSnapshot(): MatchSnapshot {
  const snapshot = { ...DEFAULTS }
  for (const key of MATCH_KEYS) {
    snapshot[key] = readStoredValue(key) ?? DEFAULTS[key]
  }
  return snapshot
}

export function serializeMatchSnapshot(snapshot: MatchSnapshot): string {
  return JSON.stringify(snapshot)
}

export function parseMatchSnapshot(text: string): MatchSnapshot | null {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null

  const record = raw as Record<string, unknown>
  const snapshot = { ...DEFAULTS }
  for (const key of MATCH_KEYS) {
    const value = record[key]
    if (typeof value !== 'string') return null
    snapshot[key] = value
  }
  return snapshot
}

// Prefers the native share sheet so a host can send the match to any app.
// Cancelling the sheet is not a failure, and a denied share falls back to the
// clipboard. Neither path may interrupt scoring on an insecure or old browser.
export async function shareMatchExport(text: string): Promise<ExportResult> {
  if (typeof navigator.share === 'function') {
    try {
      await navigator.share({ title: 'MAJADU Score', text })
      return 'shared'
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') return 'cancelled'
    }
  }

  try {
    if (!navigator.clipboard?.writeText) return 'failed'
    await navigator.clipboard.writeText(text)
    return 'copied'
  } catch {
    return 'failed'
  }
}
