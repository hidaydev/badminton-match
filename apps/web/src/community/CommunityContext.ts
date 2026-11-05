import { createContext, useContext } from 'react'
import type { Membership } from '../auth/api'

export type CommunityContextValue = {
  /** `GET /communities`: every community the signed-in account belongs to. */
  memberships: Membership[]
  /**
   * Community the shell is showing: the URL slug when the account belongs to
   * it, otherwise the stored choice, then the first membership. `null` when the
   * URL names a community the account is not a member of.
   */
  current: Membership | null
  /** Store the slug and reroute into that community without touching the session. */
  select: (slug: string) => void
}

export const CommunityContext = createContext<CommunityContextValue | null>(null)

export function useCommunity(): CommunityContextValue {
  const value = useContext(CommunityContext)
  if (value === null) throw new Error('useCommunity must be used inside CommunityProvider')
  return value
}
