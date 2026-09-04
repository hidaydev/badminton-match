// scripts/resolve-ts-imports.mjs
// Node ESM resolve hook — appends .ts/.tsx to relative extensionless imports
// (Vite resolves these via bundler resolution; plain Node ESM does not).
// Used only by `npm run check:regression`; the app itself never loads this.
import { registerHooks } from 'node:module'
import { existsSync } from 'node:fs'
import { dirname, resolve as pathResolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const TS_EXTS = ['.ts', '.tsx']
const HAS_EXTENSION = /\.(ts|tsx|js|mjs|cjs|json)$/

registerHooks({
  resolve(specifier, context, nextResolve) {
    const isRelative = specifier.startsWith('./') || specifier.startsWith('../')
    if (isRelative && !HAS_EXTENSION.test(specifier)) {
      const parentDir = dirname(
        context.parentURL && context.parentURL.startsWith('file:')
          ? fileURLToPath(context.parentURL)
          : process.cwd(),
      )
      const base = pathResolve(parentDir, specifier)
      for (const ext of TS_EXTS) {
        if (existsSync(base + ext)) {
          return nextResolve(pathToFileURL(base + ext).href, context)
        }
      }
      const indexTs = pathResolve(base, 'index.ts')
      if (existsSync(indexTs)) {
        return nextResolve(pathToFileURL(indexTs).href, context)
      }
    }
    return nextResolve(specifier, context)
  },
})
