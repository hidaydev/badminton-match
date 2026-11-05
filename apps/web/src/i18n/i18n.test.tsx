/// <reference types="node" />
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'
import { en, t } from './index'

const SRC_DIR = join(process.cwd(), 'src')

/** Visible JSX attributes that must never carry a literal. */
const VISIBLE_ATTRIBUTES = new Set(['placeholder', 'aria-label', 'aria-description', 'title', 'alt'])

/**
 * Report JSX text nodes and visible attributes that are not produced by `t()`.
 * Expressions (`{t('key')}`) are not text nodes, so they never match.
 */
export function findHardcodedStrings(source: string, fileName = 'example.tsx'): string[] {
  const file = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  const found: string[] = []

  const visit = (node: ts.Node): void => {
    if (ts.isJsxText(node)) {
      const text = node.text.trim()
      if (/[A-Za-z]/.test(text)) found.push(text)
    }
    if (ts.isJsxAttribute(node)) {
      const name = node.name.getText()
      if (VISIBLE_ATTRIBUTES.has(name) && node.initializer && ts.isStringLiteral(node.initializer)) {
        if (/[A-Za-z]/.test(node.initializer.text)) found.push(node.initializer.text)
      }
    }
    ts.forEachChild(node, visit)
  }
  visit(file)
  return found
}

// `src/legacy` is the restored pre-rewrite tree. It predates the i18n rule and
// is intentionally not rewritten, so it is not scanned here.
const SKIP_DIRS = new Set(['legacy'])

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) return SKIP_DIRS.has(entry.name) ? [] : sourceFiles(path)
    return entry.name.endsWith('.tsx') && !entry.name.endsWith('.test.tsx') ? [path] : []
  })
}

describe('i18n', () => {
  it('fills named placeholders', () => {
    expect(t('nav.signedInAs', { name: 'Ada' })).toBe('Signed in as Ada')
    expect(t('session.game.key', { round: 2, court: 3 })).toContain('3')
  })

  it('keeps every dictionary value a non-empty string', () => {
    for (const value of Object.values(en)) {
      expect(typeof value).toBe('string')
      expect(value.trim().length).toBeGreaterThan(0)
    }
  })

  it('recognises hardcoded text', () => {
    expect(findHardcodedStrings('<p>Hello</p>')).toEqual(['Hello'])
    expect(findHardcodedStrings('<input placeholder="Name" />')).toEqual(['Name'])
    expect(findHardcodedStrings("<p>{t('login.title')}</p>")).toEqual([])
    expect(findHardcodedStrings('const re = /^[a-z]+$/; const x = <p>{n}</p>')).toEqual([])
  })

  it('has no hardcoded UI strings in components', () => {
    const files = sourceFiles(SRC_DIR)
    expect(files.length).toBeGreaterThan(0)

    const offenders = files.flatMap((file) =>
      findHardcodedStrings(readFileSync(file, 'utf8'), file).map(
        (text) => `${file.slice(SRC_DIR.length)}: ${text}`,
      ),
    )
    expect(offenders).toEqual([])
  })
})
