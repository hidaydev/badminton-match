import type { CommunityRole, Membership } from '../auth/api'
import { useCommunity } from './CommunityContext'

/** What a role may do. One table, so three pages cannot derive it three ways. */
export type Capability = 'player.manage' | 'settings.edit'

const CAPABILITIES: Record<CommunityRole, readonly Capability[]> = {
  admin: ['player.manage', 'settings.edit'],
  host: ['player.manage'],
  member: [],
}

export function can(role: CommunityRole | null, capability: Capability): boolean {
  return role !== null && CAPABILITIES[role].includes(capability)
}

/** The one place the membership array is searched. */
function findMembership(
  memberships: Membership[],
  predicate: (membership: Membership) => boolean,
): Membership | null {
  return memberships.find(predicate) ?? null
}

/** The membership for a slug, without each page writing its own find. */
export function matchMembership(memberships: Membership[], slug: string | null): Membership | null {
  if (slug === null) return null
  return findMembership(memberships, (membership) => membership.slug === slug)
}

export function matchMembershipById(memberships: Membership[], id: string): Membership | null {
  return findMembership(memberships, (membership) => membership.id === id)
}

/**
 * The signed-in account's role in one community, plus the capability check.
 * The context and auth expose the same memberships array; this is the only
 * place that turns it into a role.
 */
export function useMembership(slug: string | null) {
  const { memberships } = useCommunity()
  const membership = matchMembership(memberships, slug)
  const role = membership?.role ?? null
  return {
    membership,
    role,
    can: (capability: Capability) => can(role, capability),
  }
}
