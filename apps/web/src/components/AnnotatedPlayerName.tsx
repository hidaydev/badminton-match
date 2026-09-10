// src/components/AnnotatedPlayerName.tsx — Komponen penampil nama pemain dengan anotasi penjelas (i)
import { useState } from 'react'
import { parsePlayerName } from '../utils/nameParser'

interface AnnotatedPlayerNameProps {
  name: string
  className?: string
  annotationClassName?: string
}

/**
 * Merender nama pemain. Jika nama mengandung anotasi dalam kurung (mis. "Arya (Shania)"),
 * nama ditampilkan sebagai "Arya" dengan penanda subtle "(i)" yang ketika di-hover / di-tap
 * akan menampilkan tooltip/popover nama lengkap.
 */
export default function AnnotatedPlayerName({
  name,
  className = '',
  annotationClassName = 'text-accent/90',
}: AnnotatedPlayerNameProps) {
  const { baseName, annotation } = parsePlayerName(name)
  const [showTooltip, setShowTooltip] = useState(false)

  if (!annotation) {
    return <span className={className}>{baseName}</span>
  }

  return (
    <span
      className={`inline-flex items-center gap-0.5 relative group cursor-pointer ${className}`}
      onClick={(e) => {
        e.stopPropagation()
        setShowTooltip((v) => !v)
      }}
      onMouseEnter={() => setShowTooltip(true)}
      onMouseLeave={() => setShowTooltip(false)}
      title={`${name}`}
    >
      <span className="truncate">{baseName}</span>
      <span className={`text-[0.65em] font-sans font-bold leading-none select-none px-0.5 rounded transition-opacity ${annotationClassName}`}>
        ⁽ⁱ⁾
      </span>

      {/* Floating Tooltip / Popover saat hover & tap */}
      {showTooltip && (
        <span
          className="absolute bottom-full left-1/2 -translate-x-1/2 mb-1.5 z-50 whitespace-nowrap bg-slate-900 border border-slate-700 text-slate-100 text-[11px] font-sans px-2 py-1 rounded-md shadow-xl pointer-events-none"
          role="tooltip"
        >
          {name}
        </span>
      )}
    </span>
  )
}
