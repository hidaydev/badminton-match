/**
 * The build stamp, replaced at build time by `__BUILD_VERSION__` and
 * `__BUILD_COMMIT__`. Both vite configs define them from `build-info.mjs`, so
 * the bundle and the unit tests read the same values.
 *
 * `declare` keeps tsc happy: the identifiers only exist after the bundler has
 * substituted them.
 */
declare const __BUILD_VERSION__: string
declare const __BUILD_COMMIT__: string

export const BUILD = {
  version: __BUILD_VERSION__,
  commit: __BUILD_COMMIT__,
}
