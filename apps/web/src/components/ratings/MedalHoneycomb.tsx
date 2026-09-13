// src/components/ratings/MedalHoneycomb.tsx, penataan badge medal menyerupai
// sarang lebah (honeycomb). Item dirender tanpa teks, jadi baris cukup disusun
// rapat: baris ganjil digeser setengah lebar heksagon, baris berikutnya ditarik
// naik 25% tinggi supaya sisi miringnya bersambung.
//
// Jumlah kolom dihitung dari lebar kontainer (ResizeObserver) supaya tetap rapi
// di mobile maupun desktop.
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
  for (let i = 0; i < items.length; i += perRow) {
    rows.push(items.slice(i, i + perRow))
  }

  const height = Math.round(width * HEX_RATIO)

  return (
    <div ref={ref} className="flex w-full flex-col items-center py-1">
      {rows.map((row, ri) => (
        <div
          key={ri}
          className="flex"
          style={{
            marginTop: ri === 0 ? 0 : -Math.round(height * 0.25),
            transform: ri % 2 ? `translateX(${Math.round(width / 2)}px)` : undefined,
          }}
        >
          {row.map((node, ci) => (
            <div key={ci} style={{ width, height }}>
              {node}
            </div>
          ))}
        </div>
      ))}
    </div>
  )
}
