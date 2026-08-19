// src/utils/sparkline.ts — SVG polyline rating vs waktu (tanpa library).
// Murni & deterministik — path dihasilkan dari history rating (new_rating).

export interface SparklinePoint {
  rating: number
}

/**
 * ratingSparklinePath — polyline SVG untuk deret rating.
 * Normalisasi [min,max] → area [padding, h-padding]; x merata sepanjang lebar.
 * Input diharapkan urut kronologis (paling lama dulu); API rating DESC —
 * pemanggil wajib membalik.
 */
export function ratingSparklinePath(
  history: SparklinePoint[],
  w: number,
  h: number,
  padding = 3,
): string {
  if (history.length === 0) return ''
  if (history.length === 1) {
    const y = h / 2
    return `M ${padding} ${y} L ${w - padding} ${y}`
  }

  let min = Infinity
  let max = -Infinity
  for (const p of history) {
    if (p.rating < min) min = p.rating
    if (p.rating > max) max = p.rating
  }
  const span = max - min || 1 // span 0 → garis rata

  const innerW = w - 2 * padding
  const innerH = h - 2 * padding
  const step = innerW / (history.length - 1)

  return history
    .map((p, i) => {
      const x = padding + i * step
      const y = padding + innerH - ((p.rating - min) / span) * innerH
      return `${i === 0 ? 'M' : 'L'} ${x.toFixed(2)} ${y.toFixed(2)}`
    })
    .join(' ')
}
