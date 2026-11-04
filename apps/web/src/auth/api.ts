// Auth API surface (T-028). Every call carries the HttpOnly session cookie via
// `credentials: 'include'`; no token ever reaches JavaScript, so there is
// nothing to put in localStorage or sessionStorage.

/** API contract generation this bundle was built against (TECH-SPEC §9). */
export const API_VERSION = 2

/** Fired when the server says this bundle speaks a contract it no longer serves. */
export const CLIENT_OUTDATED_EVENT = 'majadu:client-outdated'

const API_BASE = import.meta.env.VITE_API_BASE || '/api'

export type ApiProblem = {
  status: number
  code: string
  i18nKey?: string
}

export class ApiError extends Error {
  readonly status: number
  readonly code: string

  constructor(problem: ApiProblem) {
    super(`${problem.status} ${problem.code}`)
    this.name = 'ApiError'
    this.status = problem.status
    this.code = problem.code
  }
}

/** True for the one expected failure: no session cookie yet. */
export function isUnauthenticated(error: unknown): boolean {
  return error instanceof ApiError && error.status === 401
}

export async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set('X-API-Version', String(API_VERSION))
  if (init.body !== undefined) headers.set('Content-Type', 'application/json')

  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    credentials: 'include',
    headers,
  })

  if (!response.ok) {
    const problem = await response.json().catch(() => ({}))
    if (response.status === 410 && problem.code === 'CLIENT_OUTDATED') {
      window.dispatchEvent(new Event(CLIENT_OUTDATED_EVENT))
    }
    throw new ApiError({
      status: response.status,
      code: typeof problem.code === 'string' ? problem.code : 'UNKNOWN',
      i18nKey: typeof problem.i18nKey === 'string' ? problem.i18nKey : undefined,
    })
  }
  if (response.status === 204) return undefined as T
  return (await response.json()) as T
}

export type CommunityRole = 'admin' | 'host' | 'member'

export type SessionUser = {
  id: string
  displayName: string
  platformOwner: boolean
}

export type Membership = {
  id: string
  slug: string
  name: string
  role: CommunityRole
}

export function fetchMe(): Promise<SessionUser> {
  return request<SessionUser>('/auth/me')
}

export async function fetchMemberships(): Promise<Membership[]> {
  const body = await request<{ items: Membership[] }>('/communities')
  return body.items
}

/** Starts the OIDC flow; the caller navigates to `authorizeUrl`. */
export async function startLogin(returnTo: string): Promise<string> {
  const body = await request<{ authorizeUrl: string }>('/auth/start', {
    method: 'POST',
    body: JSON.stringify({ returnTo }),
  })
  return body.authorizeUrl
}

export function endSession(): Promise<void> {
  return request<void>('/auth/logout', { method: 'POST' })
}
