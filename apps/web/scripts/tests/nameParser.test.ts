import test from 'node:test'
import assert from 'node:assert/strict'
import { parsePlayerName } from '../../src/utils/nameParser.ts'

test('parsePlayerName: memecah nama dengan anotasi kurung', () => {
  assert.deepEqual(parsePlayerName('Arya (Shania)'), { baseName: 'Arya', annotation: 'Shania' })
  assert.deepEqual(parsePlayerName('Arya (Dika)'), { baseName: 'Arya', annotation: 'Dika' })
  assert.deepEqual(parsePlayerName('Andra (temen novian)'), { baseName: 'Andra', annotation: 'temen novian' })
})

test('parsePlayerName: nama polos tanpa kurung', () => {
  assert.deepEqual(parsePlayerName('Bowo'), { baseName: 'Bowo', annotation: null })
  assert.deepEqual(parsePlayerName('Tari'), { baseName: 'Tari', annotation: null })
})

test('parsePlayerName: input null/empty', () => {
  assert.deepEqual(parsePlayerName(''), { baseName: '', annotation: null })
  assert.deepEqual(parsePlayerName(null), { baseName: '', annotation: null })
})
