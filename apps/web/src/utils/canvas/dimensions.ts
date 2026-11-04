// Export sizes come from the platform config, never from code.
//
// `export.post_width`, `export.post_height`, `export.story_width` and
// `export.story_height` are registry keys (int, 320..4096, scope platform) that
// `GET /c/{slug}/config` reports in `effective`. A missing or unusable value is
// a failure, not a reason to invent a default: those are business numbers, and
// the server owns them.

import type { CommunityConfig } from '../../community/api'
import type { CanvasSize } from './geometry'

export const EXPORT_KEYS = {
  postWidth: 'export.post_width',
  postHeight: 'export.post_height',
  storyWidth: 'export.story_width',
  storyHeight: 'export.story_height',
} as const

export type ExportDimensionKey = (typeof EXPORT_KEYS)[keyof typeof EXPORT_KEYS]

/** Mirrors the registry bounds in `modules/platform/config/registry.nim`. */
export const EXPORT_MIN_DIMENSION = 320
export const EXPORT_MAX_DIMENSION = 4096

export type ExportDimensions = {
  post: CanvasSize
  story: CanvasSize
}

function readDimension(config: CommunityConfig, key: ExportDimensionKey): number {
  const entry = config[key]
  if (entry === undefined) {
    throw new Error(`export dimension "${key}" is missing from the community config`)
  }
  const value = entry.value
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new Error(
      `export dimension "${key}" must be an integer, got ${describe(value)}`,
    )
  }
  if (value < EXPORT_MIN_DIMENSION || value > EXPORT_MAX_DIMENSION) {
    throw new Error(
      `export dimension "${key}" must be between ${EXPORT_MIN_DIMENSION} and ` +
        `${EXPORT_MAX_DIMENSION}, got ${value}`,
    )
  }
  return value
}

function describe(value: unknown): string {
  if (typeof value === 'string') return `"${value}"`
  if (value === null) return 'null'
  if (typeof value === 'number') return String(value)
  return typeof value
}

/** Post and story sizes for one community, straight from the config. */
export function exportDimensions(config: CommunityConfig): ExportDimensions {
  return {
    post: {
      width: readDimension(config, EXPORT_KEYS.postWidth),
      height: readDimension(config, EXPORT_KEYS.postHeight),
    },
    story: {
      width: readDimension(config, EXPORT_KEYS.storyWidth),
      height: readDimension(config, EXPORT_KEYS.storyHeight),
    },
  }
}
