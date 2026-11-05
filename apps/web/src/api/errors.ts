/**
 * The one API failure type and the one set of server-signalled events.
 *
 * Two transports exist on purpose: `auth/api.ts` is the thin client the v2
 * screens use, `legacy/queries/endpoints.ts` adds timeout, method-aware retry
 * and conditional requests for the restored v1 tree. They must still agree on
 * what a failure *is*, otherwise `instanceof` checks and the message mapping in
 * `legacy/queries/errors.ts` silently degrade to a generic fallback when an
 * error crosses the boundary.
 */

export class ApiError extends Error {
  /** HTTP status, or `null` for failures raised before a response arrived. */
  readonly status: number | null
  /** Business code from the error body (eg `CLIENT_OUTDATED`, `STALE_VERSION`). */
  readonly code: string | null

  constructor(message: string, code: string | null = null, status: number | null = null) {
    super(message)
    this.name = 'ApiError'
    this.code = code
    this.status = status
  }
}

/** Fired when the server answers `410 CLIENT_OUTDATED`: this bundle must reload. */
export const CLIENT_OUTDATED_EVENT = 'majadu:client-outdated'

/** Fired when an authenticated request answers `401`: the session cookie is gone. */
export const SESSION_EXPIRED_EVENT = 'majadu:session-expired'

function emit(name: string): void {
  window.dispatchEvent(new Event(name))
}

/** True for the one response that means "reload before trying again". */
export function isClientOutdated(error: unknown): boolean {
  return (
    error instanceof ApiError &&
    error.status === 410 &&
    error.code === 'CLIENT_OUTDATED'
  )
}

/** Show the reload banner; nothing on the page can work with an old contract. */
export function reportClientOutdated(): void {
  emit(CLIENT_OUTDATED_EVENT)
}

/** Drop the stale user so the shell renders the login screen instead of errors. */
export function reportSessionExpired(): void {
  emit(SESSION_EXPIRED_EVENT)
}