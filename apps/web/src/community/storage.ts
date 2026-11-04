/**
 * The selected community is the only thing this app remembers locally. It is a
 * slug, not session material: the cookie stays HttpOnly and the slug is a
 * navigation preference.
 */
export const COMMUNITY_STORAGE_KEY = 'majadu.community.slug'

function storage(): Storage | null {
  try {
    return window.localStorage
  } catch {
    // Storage can be unavailable (private mode, blocked cookies); the picker
    // then stays session-only instead of breaking the shell.
    return null
  }
}

export function readStoredSlug(): string | null {
  try {
    return storage()?.getItem(COMMUNITY_STORAGE_KEY) ?? null
  } catch {
    return null
  }
}

export function writeStoredSlug(slug: string | null): void {
  try {
    const target = storage()
    if (target === null) return
    if (slug === null) target.removeItem(COMMUNITY_STORAGE_KEY)
    else target.setItem(COMMUNITY_STORAGE_KEY, slug)
  } catch {
    // Quota or security errors must not block navigation.
  }
}
