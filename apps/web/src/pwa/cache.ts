/**
 * The service worker's image cache is origin-wide, not per account. Logging out
 * (or an expired session) must delete it so the next person on a shared tablet
 * cannot read the previous user's images out of Cache Storage.
 */
export const PRIVATE_IMAGE_CACHE = 'images-cache'

export async function purgePrivateImageCaches(): Promise<void> {
  if (typeof caches === 'undefined') return
  await caches.delete(PRIVATE_IMAGE_CACHE)
}
