/**
 * The one HTTP transport. `auth/api.ts` and the legacy adapter both call this,
 * so timeout, retry, `Retry-After`, `410` and `401` behave the same on every
 * screen.
 */
import {
  ApiError,
  isClientOutdated,
  reportClientOutdated,
  reportSessionExpired,
} from './errors'
import { parseRetryAfter, shouldRetry } from '../legacy/queries/retry'

/** Same-origin `/api` path; the dev proxy and the production rewrite both strip it. */
export const API_BASE: string = import.meta.env.VITE_API_BASE || '/api'

const API_VERSION = '2'
const API_TIMEOUT_MS = 30_000
const RETRY_BASE_DELAY_MS = 1_000
const RETRY_MAX_DELAY_MS = 4_000

export type RequestOptions = {
  /** Keep the response headers for the legacy conditional-request callers. */
  includeHeaders?: boolean
  timeoutMs?: number
  maxRetries?: number
  retryBaseDelayMs?: number
}

export type RequestResult<T> = T | { data: T; headers: Headers }

function backoffDelayMs(attempt: number, base: number): number {
  return Math.min(base * 2 ** attempt, RETRY_MAX_DELAY_MS)
}

function headerRecord(init: HeadersInit | undefined): Record<string, string> {
  if (init instanceof Headers) {
    const record: Record<string, string> = {}
    init.forEach((value, key) => {
      record[key] = value
    })
    return record
  }
  if (Array.isArray(init)) return Object.fromEntries(init)
  return { ...(init ?? {}) }
}

async function parseFailure(response: Response): Promise<ApiError> {
  let message = `${response.status} ${response.statusText}`
  let code: string | null = null
  let detail: string | null = null
  try {
    const body = (await response.json()) as { detail?: string; message?: string; code?: string }
    detail = body.detail ?? body.message ?? null
    message = detail ?? message
    code = body.code ?? null
  } catch {
    // keep the status text when the body is not JSON
  }
  return new ApiError(message, code, response.status, detail)
}

export function request<T>(
  path: string,
  init?: RequestInit,
  options?: RequestOptions & { includeHeaders?: false },
): Promise<T>
export function request<T>(
  path: string,
  init: RequestInit | undefined,
  options: RequestOptions & { includeHeaders: true },
): Promise<{ data: T; headers: Headers }>
export async function request<T>(
  path: string,
  init: RequestInit = {},
  options: RequestOptions = {},
): Promise<RequestResult<T>> {
  const method = (init.method ?? 'GET').toUpperCase()
  // The legacy adapter opts into retries explicitly; a v2 screen keeps the
  // one-shot behaviour it had before the transport was unified.
  const maxRetries = options.maxRetries ?? 0
  const timeoutMs = options.timeoutMs ?? API_TIMEOUT_MS
  const retryBaseDelayMs = options.retryBaseDelayMs ?? RETRY_BASE_DELAY_MS
  let lastError: unknown
  let retryDelayMs = 0

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    if (attempt > 0) {
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs))
    }

    const timeout = new AbortController()
    const timeoutId = setTimeout(() => timeout.abort(), timeoutMs)
    const callerSignal = init.signal
    const onCallerAbort = () => timeout.abort()
    callerSignal?.addEventListener('abort', onCallerAbort)

    try {
      const headers = headerRecord(init.headers)
      if (!Object.keys(headers).some((key) => key.toLowerCase() === 'x-api-version')) {
        headers['X-API-Version'] = API_VERSION
      }
      if (
        init.body !== undefined &&
        !(init.body instanceof FormData) &&
        !Object.keys(headers).some((key) => key.toLowerCase() === 'content-type')
      ) {
        headers['Content-Type'] = 'application/json'
      }

      const response = await fetch(`${API_BASE}${path}`, {
        ...init,
        credentials: init.credentials ?? 'include',
        headers,
        signal: timeout.signal,
      })

      if (!response.ok) {
        const error = await parseFailure(response)
        // A 410 is the contract rolling forward and a 401 is the cookie going
        // away; both need the shell to react, not just the screen that called.
        if (isClientOutdated(error)) reportClientOutdated()
        if (response.status === 401) reportSessionExpired()
        if (shouldRetry(method, error, attempt, maxRetries)) {
          lastError = error
          const retryAfter = parseRetryAfter(response.headers.get('Retry-After'))
          retryDelayMs = retryAfter !== null ? retryAfter * 1_000 : backoffDelayMs(attempt, retryBaseDelayMs)
          continue
        }
        throw error
      }

      if (response.status === 204) {
        const data = undefined as T
        return options.includeHeaders === true ? { data, headers: response.headers } : data
      }
      const data = (await response.json()) as T
      return options.includeHeaders === true ? { data, headers: response.headers } : data
    } catch (error) {
      if (callerSignal?.aborted) throw error
      if (shouldRetry(method, error, attempt, maxRetries)) {
        lastError = error
        retryDelayMs = backoffDelayMs(attempt, retryBaseDelayMs)
        continue
      }
      throw error
    } finally {
      clearTimeout(timeoutId)
      callerSignal?.removeEventListener('abort', onCallerAbort)
    }
  }

  throw lastError
}
