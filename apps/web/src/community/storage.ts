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

const listeners = new Set<() => void>()

/** Subscribers re-read the slug after a write, so nothing has to mirror it in state. */
export function subscribeStoredSlug(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

function notify(): void {
  for (const listener of listeners) listener()
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
    const before = target.getItem(COMMUNITY_STORAGE_KEY)
    if (slug === null) target.removeItem(COMMUNITY_STORAGE_KEY)
    else target.setItem(COMMUNITY_STORAGE_KEY, slug)
    if (before !== slug) notify()
  } catch {
    // Quota or security errors must not block navigation.
  }
}
