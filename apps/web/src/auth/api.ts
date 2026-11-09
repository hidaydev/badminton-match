// Auth API surface (T-028). Every call carries the HttpOnly session cookie via
// `credentials: 'include'`; no token ever reaches JavaScript, so there is
// nothing to put in localStorage or sessionStorage.

import { ApiError } from '../api/errors'
import { request } from '../api/request'

/** API contract generation this bundle was built against (TECH-SPEC §9). */
export const API_VERSION = 2

/** Fired when the server says this bundle speaks a contract it no longer serves. */
export { CLIENT_OUTDATED_EVENT } from '../api/errors'

/** The shared API failure type; re-exported so screen imports stay unchanged. */
export { ApiError } from '../api/errors'

/** The shared transport; re-exported because every v2 screen imports it here. */
export { request }

/** True for the one expected failure: no session cookie yet. */
export function isUnauthenticated(error: unknown): boolean {
  return error instanceof ApiError && error.status === 401
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

export type AuthSession = {
  id: string
  createdAt: string
  lastSeenAt: string
  current: boolean
}

/** One row per device signed in to this account. */
export async function listAuthSessions(): Promise<AuthSession[]> {
  const body = await request<{ items: AuthSession[] }>('/auth/sessions')
  return body.items
}

/** Revokes every session except the one that made this call. */
export function revokeOtherAuthSessions(): Promise<void> {
  return request<void>('/auth/sessions', { method: 'DELETE' })
}
