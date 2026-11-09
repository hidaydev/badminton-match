#!/usr/bin/env node
// Reads the built service worker and asserts the precache contract the scoreboard
// depends on: no duplicated url, the install-sheet image present, the unused logo
// absent, and a total under the documented budget. A failure here is cheaper than
// discovering it on a phone in the hall.
import { existsSync, readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const appRoot = resolve(here, '..')
const swPath = join(appRoot, 'dist', 'sw.js')

if (!existsSync(swPath)) {
  console.error('precache: dist/sw.js is missing; run the build first')
  process.exit(1)
}

const sw = readFileSync(swPath, 'utf8')
const urls = [...sw.matchAll(/url:\s*"([^"]+)"/g)].map(match => match[1])
const duplicates = urls.filter((url, index) => urls.indexOf(url) !== index)

let total = 0
for (const url of urls) {
  const file = join(appRoot, 'dist', url)
  if (existsSync(file)) total += statSync(file).size
}

const problems = []
if (duplicates.length > 0) problems.push(`duplicate entries: ${[...new Set(duplicates)].join(', ')}`)
if (!urls.some(url => url.endsWith('add-to-home-screen.jpeg'))) {
  problems.push('the install sheet image add-to-home-screen.jpeg is not precached')
}
if (urls.some(url => url.includes('majadu-logo.png'))) {
  problems.push('majadu-logo.png is precached but never rendered')
}

const BUDGET = 300 * 1024
console.log(`precache: ${urls.length} entries, ${(total / 1024).toFixed(1)} KiB (budget ${BUDGET / 1024} KiB)`)
if (total > BUDGET) problems.push(`precache is ${(total / 1024).toFixed(1)} KiB, over the ${BUDGET / 1024} KiB budget`)

if (problems.length > 0) {
  console.error('precache:')
  for (const problem of problems) console.error(`  ${problem}`)
  process.exit(1)
}

console.log('precache: ok')
