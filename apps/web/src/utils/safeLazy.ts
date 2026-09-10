import { lazy, type ComponentType } from 'react'

export function isChunkLoadError(error: unknown): boolean {
  if (!error) return false
  const err = error as { name?: string; message?: string }
  const name = err.name ?? ''
  const msg = err.message ?? ''
  return (
    name === 'ChunkLoadError' ||
    /failed to fetch dynamically imported module/i.test(msg) ||
    /importing a module script failed/i.test(msg) ||
    /error loading dynamically imported module/i.test(msg)
  )
}

/**
 * safeLazy — Wrapper untuk React.lazy yang otomatis men-trigger window.location.reload()
 * saat terjadi error chunk loading (misal: akibat deployment baru di Vercel yang mengubah hash bundle JS).
 *
 * Menggunakan sessionStorage guard ('majadu_chunk_reload_retry') agar tidak infinite loop
 * jika koneksi user memang benar-benar offline/terputus.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function safeLazy<T extends ComponentType<any>>(
  factory: () => Promise<{ default: T }>
) {
  return lazy(async () => {
    try {
      const page = await factory()
      if (typeof window !== 'undefined' && window.sessionStorage) {
        window.sessionStorage.removeItem('majadu_chunk_reload_retry')
      }
      return page
    } catch (error) {
      if (typeof window !== 'undefined' && isChunkLoadError(error)) {
        const key = 'majadu_chunk_reload_retry'
        const hasRetried = window.sessionStorage?.getItem(key)
        if (!hasRetried) {
          window.sessionStorage?.setItem(key, 'true')
          window.location.reload()
          return new Promise<{ default: T }>(() => {})
        }
        window.sessionStorage?.removeItem(key)
      }
      throw error
    }
  })
}
