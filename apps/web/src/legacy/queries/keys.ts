// src/legacy/queries/keys.ts
// Every cache entry that belongs to a community is prefixed with the active
// slug. Switching community therefore cannot read the previous community's
// entries, and invalidating a family only touches the current community.

import { activeCommunitySlug } from './endpoints'

/** Prefix a query key with the active community slug. */
export function communityQueryKey(...parts: readonly unknown[]): readonly unknown[] {
  return [activeCommunitySlug(), ...parts]
}