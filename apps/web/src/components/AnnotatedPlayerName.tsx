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
      className={`inline-flex items-center min-w-0 max-w-full relative group cursor-pointer ${className}`}
      onClick={(e) => {
        e.stopPropagation()
        setShowTooltip((v) => !v)
      }}
      onMouseEnter={() => setShowTooltip(true)}
      onMouseLeave={() => setShowTooltip(false)}
      title={`${name}`}
    >
      <span className="whitespace-nowrap min-w-0">{baseName}</span>
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
        className={`w-3 h-3 shrink-0 ${annotationClassName}`}
        aria-hidden="true"
      >
        <path
          fillRule="evenodd"
          d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a.75.75 0 000 1.5h.25v3.25a.75.75 0 001.5 0v-4A.75.75 0 0010 9H9z"
          clipRule="evenodd"
        />
      </svg>

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
