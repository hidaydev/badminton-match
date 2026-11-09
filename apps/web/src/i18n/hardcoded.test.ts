// ISO-23: the legacy tree still bypassed the dictionary. This test is the
// lint: it walks the restored screens and fails on a copy string that is not
// resolved through `t()`.
//
// The shape it reads is the one those files use: a JSX text node that occupies
// its own line, and a `title`/`aria-label`/`placeholder`/`alt` literal. Code,
// imports and expressions are skipped, because a rule that also flags
// identifiers teaches people to ignore it.

import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const COPY_ATTRIBUTES = ['aria-label', 'placeholder', 'title', 'alt'] as const
const COPY_ATTRIBUTE = new RegExp(
  `\\b(${COPY_ATTRIBUTES.join('|')})="([^"]*)"`,
  'g',
)
/** Text a person reads: capitalised, no punctuation that only code uses. */
const TEXT_NODE = /^[A-Za-z0-9 ,.'’!?&()+-]+$/
const CODE_CHARACTERS = /[<>={};:[\]()`|]/
const IMPORT_FROM = /\bfrom\s+['"]/

export type Finding = { file: string; line: number; text: string }

export function findHardcodedStrings(source: string, file: string): Finding[] {
  const findings: Finding[] = []
  let inImport = false
  source.split('\n').forEach((line, index) => {
    const text = line.trim()
    if (inImport) {
      if (IMPORT_FROM.test(line)) inImport = false
      return
    }
    if (text.startsWith('import ')) {
      if (!IMPORT_FROM.test(line)) inImport = true
      return
    }
    if (text.length === 0 || text.startsWith('//') || text.startsWith('*') ||
        text.startsWith('/*')) {
      return
    }
    for (const match of line.matchAll(COPY_ATTRIBUTE)) {
      if (/[a-z]/.test(match[2])) {
        findings.push({ file, line: index + 1, text: `${match[1]}="${match[2]}"` })
      }
    }
    if (CODE_CHARACTERS.test(text)) return
    if (!/^[A-Z0-9]/.test(text) || !/[a-z]/.test(text)) return
    if (!TEXT_NODE.test(text)) return
    findings.push({ file, line: index + 1, text })
  })
  return findings
}

function legacySources(root: string): string[] {
  const files: string[] = []
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) {
      files.push(...legacySources(path))
      continue
    }
    if (!entry.name.endsWith('.tsx') || entry.name.includes('.test.')) continue
    files.push(path)
  }
  return files
}

describe('legacy copy', () => {
  it('is read from the dictionary, not written into the components', () => {
    const root = join(process.cwd(), 'src/legacy')
    const findings = legacySources(root).flatMap((file) =>
      findHardcodedStrings(readFileSync(file, 'utf8'), file.replace(`${root}/`, '')),
    )
    expect(
      findings.map((finding) => `${finding.file}:${finding.line}: ${finding.text}`),
    ).toEqual([])
  })

  it('flags a text node and a copy attribute', () => {
    const findings = findHardcodedStrings(
      [
        '<button>Save changes</button>',
        '<input placeholder="Player name" />',
        '<span>{t(\'common.next\')}</span>',
      ].join('\n'),
      'fixture.tsx',
    )
    expect(findings.map((finding) => finding.text)).toEqual(['placeholder="Player name"'])
  })

  it('reads a standalone text node as copy', () => {
    const findings = findHardcodedStrings(
      ['<button', '>', '  Retry', '</button>'].join('\n'),
      'fixture.tsx',
    )
    expect(findings.map((finding) => finding.text)).toEqual(['Retry'])
  })

  it('ignores imports, comments and code', () => {
    const findings = findHardcodedStrings(
      [
        "import { Link, Navigate } from 'react-router-dom'",
        'import {',
        '  Button,',
        '} from "./ui"',
        '// Retry keeps the row',
        'const label = computeLabel()',
        'export default function Page() {',
        '  return <p className="text-sm">ok</p>',
        '}',
      ].join('\n'),
      'fixture.tsx',
    )
    expect(findings).toEqual([])
  })
})
