#!/usr/bin/env node
// Fails when docs/design-system.md cites a file that does not exist.
// Only backticked tokens with a slash and a known extension are checked; the
// document quotes class names and props in the same backticks.
import { readFileSync, statSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const appRoot = resolve(here, '..')
const repoRoot = resolve(appRoot, '..', '..')
const doc = join(repoRoot, 'docs', 'design-system.md')

const EXTENSIONS = ['.ts', '.tsx', '.mjs', '.css', '.md', '.json']
const ROOT_PREFIXES = ['apps/', 'docs/', 'packages/', 'tools/', 'task.d/']

const source = readFileSync(doc, 'utf8')
const tokens = source.match(/`[^`\n]+`/g) ?? []
const paths = new Set()

for (const raw of tokens) {
  const token = raw.slice(1, -1).trim()
  if (!token.includes('/')) continue
  if (!EXTENSIONS.some(ext => token.endsWith(ext))) continue
  paths.add(token)
}

const missing = []
for (const token of paths) {
  const base = ROOT_PREFIXES.some(prefix => token.startsWith(prefix)) ? repoRoot : appRoot
  const target = resolve(base, token)
  let found = false
  try {
    found = statSync(target).isFile()
  } catch {
    found = false
  }
  if (!found) missing.push(token)
}

if (missing.length > 0) {
  console.error('doc paths: cited files that do not exist:')
  for (const token of missing) console.error(`  ${token}`)
  process.exit(1)
}

console.log(`doc paths: ok (${paths.size} cited files)`)
