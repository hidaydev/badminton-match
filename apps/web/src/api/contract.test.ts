import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { matchesRoute } from '@majadu/web-client/match'

// Vitest runs with the package as its root, so every app-relative path here
// is resolved from the web app.
const SRC = join(process.cwd(), 'src')

// The new layer, not the legacy adapter: these are the modules that typed a
// path by hand and should have it checked against the contract.
const MODULES = ['api', 'auth', 'community', 'players', 'share']

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap(name => {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) return sourceFiles(path)
    if (!name.endsWith('.ts') && !name.endsWith('.tsx')) return []
    if (name.includes('.test.')) return []
    return [path]
  })
}

/** The path literal of every `request<...>(...)` call in the new layer. */
function requestPaths(): Array<{ file: string; path: string }> {
  const found: Array<{ file: string; path: string }> = []
  for (const dir of MODULES) {
    for (const file of sourceFiles(join(SRC, dir))) {
      const source = readFileSync(file, 'utf8')
      const pattern = /request<[^>]*>\(\s*(?:'([^']+)'|`([^`]+)`)/g
      for (const match of source.matchAll(pattern)) {
        found.push({ file, path: match[1] ?? match[2] })
      }
    }
  }
  return found
}

describe('request call sites', () => {
  it('finds the hand written paths, so the assertion is not vacuous', () => {
    expect(requestPaths().length).toBeGreaterThan(20)
  })

  it('names a route the contract declares', () => {
    const unknown = requestPaths().filter(({ path }) => !matchesRoute(path.split('?')[0]))
    expect(unknown).toEqual([])
  })
})
