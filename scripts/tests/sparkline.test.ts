import test from 'node:test'
import assert from 'node:assert/strict'
import { ratingSparklinePath } from '../../src/utils/sparkline.ts'

test('sparkline: kosong → path kosong', () => {
  assert.equal(ratingSparklinePath([], 320, 56), '')
})

test('sparkline: satu titik → garis tengah', () => {
  const p = ratingSparklinePath([{ rating: 1250 }], 100, 50)
  assert.ok(p.startsWith('M 3 25 L 97 25'), `path: ${p}`)
})

test('sparkline: deterministik', () => {
  const hist = [
    { rating: 1250 }, { rating: 1310 }, { rating: 1280 }, { rating: 1370 },
  ]
  const a = ratingSparklinePath(hist, 320, 56)
  const b = ratingSparklinePath(hist, 320, 56)
  assert.equal(a, b)
})

test('sparkline: rating naik → garis naik (y mengecil)', () => {
  // 2 titik: rating naik → y akhir < y awal (SVG y ke bawah)
  const p = ratingSparklinePath([{ rating: 1200 }, { rating: 1600 }], 100, 50, 3)
  const [, x1, y1, , x2, y2] = p.split(/\s+/).map(Number)
  assert.equal(x1, 3)
  assert.ok(y2 < y1, `y2(${y2}) harus < y1(${y1}) untuk rating naik`)
  assert.equal(x2, 97)
})

test('sparkline: span nol (rating konstan) → garis rata, tidak NaN', () => {
  const p = ratingSparklinePath([{ rating: 1300 }, { rating: 1300 }, { rating: 1300 }], 100, 50)
  assert.ok(!p.includes('NaN'), `path: ${p}`)
  const ys = p.match(/\d+\.?\d* \d+\.?\d*/g)!.map((m) => Number(m.split(' ')[1]))
  assert.ok(ys.every((y) => y === ys[0]), 'semua y sama untuk rating konstan')
})
