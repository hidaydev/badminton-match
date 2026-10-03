import { useRef, useEffect } from 'react'
import { useEscapeKey } from '../hooks/useEscapeKey'

interface CelebrationOverlayProps {
  onDismiss(): void
}

const COLORS = [
  '#e3b341', '#ffffff', '#5fb58f', '#d65a5a',
  '#6d9dc8', '#e8cd83', '#82c6a6', '#e08d89',
]

const PARTICLES = Array.from({ length: 60 }, (_, i) => ({
  id: i,
  left: `${(i * 1.7 + Math.sin(i) * 11) % 100}%`,
  color: COLORS[i % COLORS.length],
  width: 6 + (i % 5) * 2,
  height: 10 + (i % 4) * 3,
  delay: `-${((i * 0.17) % 3).toFixed(2)}s`,
  duration: `${2.5 + (i % 5) * 0.4}s`,
  borderRadius: i % 3 === 0 ? '50%' : '2px',
}))

export default function CelebrationOverlay({ onDismiss }: CelebrationOverlayProps) {
  const overlayRef = useRef<HTMLDivElement>(null)

  useEscapeKey(onDismiss)

  useEffect(() => { overlayRef.current?.focus() }, [])

  return (
    <div
      ref={overlayRef}
      tabIndex={-1}
      className="fixed inset-0 z-50 flex items-center justify-center overflow-hidden bg-black/80"
      onClick={onDismiss}
      role="dialog"
      aria-modal="true"
      aria-label="Team celebration"
    >
      {/* Confetti layer — pointer-events none so tap always hits backdrop */}
      <div className="absolute inset-0 pointer-events-none" aria-hidden="true">
        {PARTICLES.map((p) => (
          <div
            key={p.id}
            className="absolute top-0"
            style={{
              left: p.left,
              width: p.width,
              height: p.height,
              background: p.color,
              borderRadius: p.borderRadius,
              animation: `confettiFall ${p.duration} ${p.delay} linear infinite`,
            }}
          />
        ))}
      </div>

      {/* Team photo */}
      <img
        src="/team-winner.png"
        alt="Majadu Badminton Club — Champions"
        className="relative z-10 object-contain drop-shadow-2xl animate-[fadeInScale_0.4s_ease-out]"
        style={{ maxHeight: '72vh', maxWidth: '90vw' }}
        draggable={false}
        onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
      />
    </div>
  )
}
