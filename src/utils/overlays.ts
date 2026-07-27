// src/utils/overlays.ts
// Shared overlay image loading utility.

import { loadImage } from './canvasPost'

/**
 * Load multiple images by path, skipping any that fail.
 * Returns an object with the loaded images keyed by name.
 *
 * @param paths — Record of key → image path. Undefined paths are skipped.
 * @returns Record of key → HTMLImageElement (only successfully loaded images)
 */
export async function loadOverlayImages<T extends Record<string, string | undefined>>(
  paths: T,
): Promise<{ [K in keyof T]?: HTMLImageElement }> {
  const result: Record<string, HTMLImageElement> = {}
  const entries = Object.entries(paths).filter(([, path]) => path !== undefined)

  const results = await Promise.allSettled(
    entries.map(async ([key, path]) => {
      const img = await loadImage(path!)
      return { key, img }
    }),
  )

  for (const r of results) {
    if (r.status === 'fulfilled') {
      result[r.value.key] = r.value.img
    }
  }

  return result as { [K in keyof T]?: HTMLImageElement }
}
