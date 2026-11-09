#!/usr/bin/env node
// PWA-04: the precache is a silent filter. Workbox drops a file above
// `maximumFileSizeToCacheInBytes` with a build warning, and the offline shell
// then loads without that module. This reads the built index.html, the service
// worker and the assets, and fails when the shell references a JS file the
// precache does not list. It also prints the cap and the largest chunk so the
// margin is visible in CI.
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const appRoot = resolve(here, '..')
const dist = join(appRoot, 'dist')
const htmlPath = join(dist, 'index.html')
const swPath = join(dist, 'sw.js')

if (!existsSync(htmlPath) || !existsSync(swPath)) {
  console.error('precache: dist/index.html or dist/sw.js is missing; run the build first')
  process.exit(1)
}

const config = readFileSync(join(appRoot, 'vite.config.ts'), 'utf8')
const capMatch = config.match(/maximumFileSizeToCacheInBytes:\s*([0-9*\s]+)/)
const cap = capMatch ? eval(capMatch[1]) : null // eslint-disable-line no-eval

const html = readFileSync(htmlPath, 'utf8')
const referenced = new Set(
  [...html.matchAll(/(?:src|href)="(\/assets\/[^"]+\.js)"/g)].map(match => match[1]),
)

const sw = readFileSync(swPath, 'utf8')
// Workbox writes precache URLs without the leading slash; index.html uses
// same-origin absolute paths. Compare on the same shape.
const normalize = url => url.replace(/^\//, '')
const precached = new Set([...sw.matchAll(/url:\s*"([^"]+)"/g)].map(match => normalize(match[1])))

const missing = [...referenced].filter(url => !precached.has(normalize(url)))

const assetsDir = join(dist, 'assets')
const assets = existsSync(assetsDir)
  ? readdirSync(assetsDir)
      .filter(name => name.endsWith('.js'))
      .map(name => ({ name, size: statSync(join(assetsDir, name)).size }))
      .sort((a, b) => b.size - a.size)
  : []
const largest = assets[0]

if (cap !== null && largest !== undefined) {
  const margin = cap - largest.size
  console.log(
    `precache: cap ${cap} bytes, largest ${largest.name} ${largest.size} bytes, margin ${margin} bytes`,
  )
}

if (missing.length > 0) {
  console.error('precache: the shell references JS that is not in the precache:')
  for (const url of missing) console.error(`  ${url}`)
  process.exit(1)
}

console.log(`precache: ok (${referenced.size} shell scripts, ${precached.size} entries)`)
