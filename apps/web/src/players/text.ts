import { ApiError } from '../auth/api'
import { t } from '../i18n'

/** One set of sentences for every player write, so the pages cannot drift. */
export function describePlayerError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 403) return t('players.error.forbidden')
    // The route answers CONFLICT when the player still owns matches or
    // sessions; that is not the same sentence as a duplicate name.
    if (error.status === 409) {
      if (error.code === 'CONFLICT') return t('players.error.inUse')
      if (error.code === 'CLAIMANT_OWNS_PLAYER') return t('players.error.claimantHasPlayer')
      return t('players.error.conflict')
    }
    if (error.status === 400) return t('players.error.invalid')
  }
  return t('players.error.save')
}

/** The aliases field is a comma-separated list, as the create form shows it. */
export function parseAliases(value: string): string[] {
  return value
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry !== '')
}
