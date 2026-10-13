import { useState, useEffect, useRef } from 'react'
import { useEscapeKey } from '../hooks/useEscapeKey'

interface CelebrationOverlayProps {
  onDismiss(): void
}

const WINNER = {
  name: 'Green Grove',
  photo: '/team-photos/green-grove.webp',
  logo: '/team-logos/Green_Grove-removebg-preview.png',
  logoSize: '8rem',
  label: 'Champion',
  emoji: '🏆',
  accent: '#5fb58f',
  glow: 'rgba(95,181,143,0.35)',
}

const RUNNER_UP = {
  name: 'Blue Waves',
  photo: '/team-photos/blue-waves.webp',
  logo: '/team-logos/Blue_Waves-removebg-preview.png',
  logoSize: '7rem',
  label: 'Runner-Up',
  emoji: '🥈',
  accent: '#6d9dc8',
  glow: 'rgba(109,157,200,0.35)',
}

const FLIP_INTERVAL = 8000  // ms per slide

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
  duration: `${5.5 + (i % 5) * 0.8}s`,
  borderRadius: i % 3 === 0 ? '50%' : '2px',
}))

const SLIDES = [WINNER, RUNNER_UP]

export default function CelebrationOverlay({ onDismiss }: CelebrationOverlayProps) {
  const [idx, setIdx] = useState(0)
  const [visible, setVisible] = useState(true)
  const overlayRef = useRef<HTMLDivElement>(null)

  useEscapeKey(onDismiss)
  useEffect(() => { overlayRef.current?.focus() }, [])

  // Auto-flip between winner and runner-up
  useEffect(() => {
    const timer = setInterval(() => {
      setVisible(false)
      setTimeout(() => {
        setIdx((i) => (i + 1) % SLIDES.length)
        setVisible(true)
      }, 350)
    }, FLIP_INTERVAL)
    return () => clearInterval(timer)
  }, [])

  const slide = SLIDES[idx]

  return (
    <div
      ref={overlayRef}
      tabIndex={-1}
      className="fixed inset-0 z-50 flex flex-col items-center justify-center overflow-hidden"
      style={{ background: 'rgba(8,10,14,0.92)' }}
      onClick={onDismiss}
      role="dialog"
      aria-modal="true"
      aria-label="Championship celebration"
    >
      {/* Confetti */}
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

      {/* Anniversary logo — top center, outside animated slide so it stays fixed */}
      <div className="absolute top-6 left-0 right-0 flex justify-center z-10 pointer-events-none" aria-hidden="true">
        <img src="/anniversary-card-logo.png" alt="" className="h-14 w-auto" draggable={false} />
      </div>

      {/* Slide content */}
      <div
        className="relative z-10 flex flex-col items-center gap-4 px-6 text-center"
        style={{
          opacity: visible ? 1 : 0,
          transform: visible ? 'scale(1) translateY(0)' : 'scale(0.94) translateY(12px)',
          transition: 'opacity 0.35s ease, transform 0.35s ease',
        }}
        aria-live="polite"
      >
        {/* Label */}
        <div className="flex flex-col items-center gap-1">
          <span
            className="text-xs font-semibold uppercase tracking-[0.25em] px-3 py-1 rounded-full"
            style={{ background: `${slide.glow}`, color: slide.accent, border: `1px solid ${slide.accent}40` }}
          >
            {slide.emoji} {slide.label}
          </span>
        </div>

        {/* Team photo + logo badge */}
        <div className="relative flex flex-col items-center">
          <img
            src={slide.photo}
            alt={`${slide.name} — ${slide.label}`}
            className="block object-cover"
            style={{
              maxHeight: '54vh', maxWidth: '86vw', minWidth: 200, display: 'block',
              filter: `drop-shadow(0 0 32px ${slide.accent}99) drop-shadow(0 0 8px ${slide.accent}55)`,
            }}
            draggable={false}
            onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
          />
          {/* Team logo — half overlapping the photo bottom */}
          <img
            src={slide.logo}
            alt={slide.name}
            className="absolute object-contain"
            style={{ bottom: '-3.5rem', width: slide.logoSize, height: slide.logoSize, filter: `drop-shadow(0 0 16px ${slide.accent}cc)` }}
            draggable={false}
            onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
          />
        </div>
        {/* Spacer to push content below the logo overhang */}
        <div style={{ height: '3.5rem' }} />
      </div>

      {/* Logo + dot indicators */}
      <div className="absolute bottom-12 flex flex-col items-center gap-3 z-10" aria-hidden="true">
        <img src="/majadu-logo.png" alt="Majadu" className="h-8 w-auto opacity-80" draggable={false} />
        <div className="flex gap-2">
        {SLIDES.map((_, i) => (
          <div
            key={i}
            className="rounded-full transition-all duration-300"
            style={{
              width: i === idx ? 20 : 6,
              height: 6,
              background: i === idx ? SLIDES[i].accent : 'rgba(255,255,255,0.25)',
            }}
          />
        ))}
        </div>
      </div>

      {/* Dismiss hint */}
      <p className="absolute bottom-6 text-[11px] text-fg-dim/50 z-10 tracking-wide pointer-events-none">
        tap anywhere to close
      </p>
    </div>
  )
}
