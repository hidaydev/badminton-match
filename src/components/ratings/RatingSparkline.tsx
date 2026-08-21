// src/components/ratings/RatingSparkline.tsx — sparkline SVG rating.
import { ratingSparklinePath, type SparklinePoint } from '../../utils/sparkline'

export default function RatingSparkline({
  points,
  width = 320,
  height = 56,
  stroke = 'var(--color-accent)',
}: {
  points: SparklinePoint[]
  width?: number
  height?: number
  stroke?: string
}) {
  const path = ratingSparklinePath(points, width, height)
  if (!path) {
    return <div className="h-14 flex items-center justify-center text-[10px] text-fg-dim font-sans">no history</div>
  }

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="w-full"
      style={{ height }}
      role="img"
      aria-label="Rating history sparkline"
    >
      <path d={path} fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}
