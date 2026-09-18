import test from 'node:test'
import assert from 'node:assert/strict'
import { parsePlayerName, collectAmbiguousBaseNames } from '../../src/utils/nameParser.ts'

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

test('collectAmbiguousBaseNames: baseName unik tidak ambigu (Miqdad case)', () => {
  // "Miqdad (Teman Ismet)" sendirian → Miqdad tidak ambigu → badge (i) jangan tampil.
  const set = collectAmbiguousBaseNames(['Miqdad (Teman Ismet)', 'Bowo', 'Tari'])
  assert.equal(set.has('miqdad'), false)
  assert.equal(set.size, 0)
})

test('collectAmbiguousBaseNames: baseName duplikat ambigu (Arya case)', () => {
  // Dua Arya berbeda → ambigu → badge (i) tampil.
  const set = collectAmbiguousBaseNames(['Arya (Shania)', 'Arya (Dika)', 'Bowo'])
  assert.equal(set.has('arya'), true)
  assert.equal(set.size, 1)
})

test('collectAmbiguousBaseNames: duplikat tanpa anotasi juga ambigu', () => {
  const set = collectAmbiguousBaseNames(['Bowo', 'bowo', 'Tari'])
  assert.equal(set.has('bowo'), true)
})

test('collectAmbiguousBaseNames: case-insensitive & abaikan kosong', () => {
  const set = collectAmbiguousBaseNames(['', 'Arya (Shania)', 'arya (Dika)'])
  assert.equal(set.has('arya'), true)
  assert.equal(set.size, 1)
})
