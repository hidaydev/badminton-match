import { describe, expect, it } from 'vitest'
import { collectAmbiguousBaseNames, combineAmbiguous, parsePlayerName } from '../nameParser'

describe('parsePlayerName', () => {
  it('splits an annotated name and leaves a plain name unannotated', () => {
    expect(parsePlayerName('Arya (Shania)')).toEqual({ baseName: 'Arya', annotation: 'Shania' })
    expect(parsePlayerName('Bowo')).toEqual({ baseName: 'Bowo', annotation: null })
  })

  it('keeps the annotation text as written and trims both halves', () => {
    expect(parsePlayerName('  Andra (temen novian) ')).toEqual({
      baseName: 'Andra',
      annotation: 'temen novian',
    })
  })

  it('returns an empty base name for a missing name', () => {
    expect(parsePlayerName(null)).toEqual({ baseName: '', annotation: null })
    expect(parsePlayerName(undefined)).toEqual({ baseName: '', annotation: null })
    expect(parsePlayerName('   ')).toEqual({ baseName: '', annotation: null })
  })

  it('treats parentheses with nothing before them as part of the name', () => {
    expect(parsePlayerName('(Shania)')).toEqual({ baseName: '(Shania)', annotation: null })
  })
})

describe('collectAmbiguousBaseNames', () => {
  it('compares case-insensitively and ignores a name that appears once', () => {
    const ambiguous = collectAmbiguousBaseNames([
      'Arya (Dika)',
      'arya (Shania)',
      'Bowo',
      'Bowo',
      'Candra',
    ])

    expect([...ambiguous].sort()).toEqual(['arya', 'bowo'])
  })

  it('skips blank names', () => {
    const ambiguous = collectAmbiguousBaseNames(['', '   ', ''])

    expect([...ambiguous]).toEqual([])
  })
})

describe('combineAmbiguous', () => {
  it('unions the global set with the local sets without touching the global one', () => {
    const global = new Set(['arya'])
    const local = new Set(['bowo'])
    const other = new Set(['arya', 'candra'])

    const combined = combineAmbiguous(global, local, other)

    expect([...combined].sort()).toEqual(['arya', 'bowo', 'candra'])
    expect([...global]).toEqual(['arya'])
    expect(combined).not.toBe(global)
  })
})