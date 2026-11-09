import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const PAGES = join(process.cwd(), 'src', 'pages')

function pageFiles(dir: string): string[] {
  return readdirSync(dir).flatMap(name => {
    const path = join(dir, name)
    if (statSync(path).isDirectory()) return pageFiles(path)
    return name.endsWith('.tsx') && !name.includes('.test.') ? [path] : []
  })
}

/**
 * A ring without a colour inherits the browser default, which is invisible on
 * this palette. Every `focus-visible:ring-*` in a page must name a colour
 * token, or the element should use the shared `focus-ring` utility.
 */
describe('page focus rings', () => {
  it('never declares a ring without a colour', () => {
    const offenders: string[] = []
    for (const file of pageFiles(PAGES)) {
      for (const [index, line] of readFileSync(file, 'utf8').split('\n').entries()) {
        if (!line.includes('focus-visible:ring-2')) continue
        if (/focus-visible:ring-(accent|error|white|offset-|ground|fg)/.test(line)) continue
        offenders.push(`${file}:${index + 1}`)
      }
    }
    expect(offenders).toEqual([])
  })
})
