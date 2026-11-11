/**
 * One declaration for every retry policy on the v2 screens. The numbers were
 * spread over the query client, the boot sequence, the share poll and the
 * transport; keeping them here means a cadence change is one edit and the
 * four consumers cannot drift.
 *
 * They stay different policies on purpose: the boot sequence waits for a
 * connection, the share screen polls, and the transport retries a request.
 */
/** The query client's default: one automatic retry for a failed read. */
export const QUERY_RETRY_COUNT = 1

/**
 * How long an answer stays usable before a mount asks again. Long enough that
 * two screens mounting the same list share one read, short enough that a write
 * on another device shows up on the next navigation.
 */
export const QUERY_STALE_MS = 30_000

/** Boot backoff before a transport failure is allowed to look like "signed out". */
export const BOOT_RETRY_MS = [1_000, 3_000, 8_000] as const

/** A spectator polls gently: the share limiter allows 120 reads/minute per code. */
export const POLL_INTERVAL_MS = 10_000
/** Backoff cap after a failure or a `429`. */
export const POLL_MAX_INTERVAL_MS = 60_000

/** Delay before the next poll after `failures` consecutive failures. */
export function pollDelayMs(failures: number): number {
  return Math.min(POLL_MAX_INTERVAL_MS, POLL_INTERVAL_MS * 2 ** failures)
}

/** Transport retry: exponential from `base`, capped. */
export const RETRY_BASE_DELAY_MS = 1_000
export const RETRY_MAX_DELAY_MS = 4_000

export function retryDelayMs(attempt: number, base = RETRY_BASE_DELAY_MS): number {
  return Math.min(base * 2 ** attempt, RETRY_MAX_DELAY_MS)
}
