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
  // Baris ganjil digeser setengah lebar, jadi kapasitasnya dikurangi satu supaya
  // total lebarnya tetap di dalam kontainer (kalau tidak, badge terakhir
  // terpotong/keluar layar di mobile).
  for (let i = 0, ri = 0; i < items.length; ri++) {
    const cap = ri % 2 === 0 || perRow < 2 ? perRow : perRow - 1
    rows.push(items.slice(i, i + cap))
    i += cap
  }

  const height = Math.round(width * HEX_RATIO)
  // Semua baris dipaksa selebar perRow*width dan rata kiri, lalu baris ganjil
  // diberi padding setengah lebar. Ini penting: kalau baris dipusatkan
  // (items-center) baris terakhir yang tidak penuh akan tergeser sendiri dan
  // bertabrakan dengan baris di atasnya — itu yang bikin overlap di mobile.
  const gridWidth = perRow * width

  return (
    <div ref={ref} className="flex w-full flex-col items-center py-1">
      <div className="flex flex-col" style={{ width: gridWidth }}>
        {rows.map((row, ri) => (
          <div
            key={ri}
            className="flex"
            style={{
              marginTop: ri === 0 ? 0 : -Math.round(height * 0.25),
              paddingLeft: ri % 2 && perRow >= 2 ? Math.round(width / 2) : 0,
            }}
          >
            {row.map((node, ci) => (
              <div key={ci} style={{ width, height, flex: 'none' }}>
                {node}
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  )
}
