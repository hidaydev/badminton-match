// src/components/ratings/MedalHoneycomb.tsx: lays the medal badges out like a
// honeycomb. The items carry no text, so the rows have to sit tight: odd rows
// are shifted half a hexagon width and the next row is pulled up by 25 percent
// of its height so the slanted sides meet.
//
// The column count comes from the container width (ResizeObserver) so the grid
// stays tidy on mobile and on desktop.
import { useEffect, useRef, useState, type ReactNode } from 'react'

interface MedalHoneycombProps {
  items: ReactNode[]
  /** Lebar satu heksagon; tinggi diturunkan dari rasio √3:2. */
  width?: number
}

const HEX_RATIO = 54 / 46.8

export default function MedalHoneycomb({ items, width = 64 }: MedalHoneycombProps) {
  const ref = useRef<HTMLDivElement>(null)
  const [perRow, setPerRow] = useState(4)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const update = () => setPerRow(Math.max(1, Math.floor(el.clientWidth / width)))
    update()
    const ro = new ResizeObserver(update)
    ro.observe(el)
    return () => ro.disconnect()
  }, [width])

  const rows: ReactNode[][] = []
  // Odd rows are shifted half a width, so their capacity drops by one to keep
  // the total width inside the container; otherwise the last badge is clipped or
  // runs off screen on mobile.
  for (let i = 0, ri = 0; i < items.length; ri++) {
    const cap = ri % 2 === 0 || perRow < 2 ? perRow : perRow - 1
    rows.push(items.slice(i, i + cap))
    i += cap
  }

  const height = Math.round(width * HEX_RATIO)
  // Every row is forced to perRow*width and left aligned, then odd rows get half
  // a width of padding. This matters: centring the rows (items-center) would
  // shift the last, partially filled row on its own until it collides with the
  // row above, which is what produced the overlap on mobile.
  const gridWidth = perRow * width

  return (
    <div ref={ref} className="flex w-full flex-col items-center py-1">
      <div className="flex flex-col" style={{ width: gridWidth }}>
        {rows.map((row, ri) => (
          <div
            key={ri}
            className="flex relative hover:z-10"
            style={{
              marginTop: ri === 0 ? 0 : -Math.round(height * 0.25),
              paddingLeft: ri % 2 && perRow >= 2 ? Math.round(width / 2) : 0,
            }}
          >
            {row.map((node, ci) => (
              <div key={ci} className="relative hover:z-20" style={{ width, height, flex: 'none' }}>
                {node}
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  )
}
