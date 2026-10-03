import { useRef, useEffect } from 'react'
import { useEscapeKey } from '../hooks/useEscapeKey'

interface AnnivBannerOverlayProps {
  onDismiss(): void
}

const SPARKLES = Array.from({ length: 36 }, (_, i) => ({
  id: i,
  left: `${(i * 2.8 + Math.sin(i * 1.3) * 15 + 50) % 100}%`,
  bottom: `${(i * 7) % 40}%`,
  size: 4 + (i % 5) * 3,
  delay: `-${((i * 0.23) % 4).toFixed(2)}s`,
  duration: `${3 + (i % 4) * 0.7}s`,
  color: ['#e3b341', '#f5d278', '#ffffff', '#e8cd83', '#ffeaa0'][i % 5],
}))

export default function AnnivBannerOverlay({ onDismiss }: AnnivBannerOverlayProps) {
  const overlayRef = useRef<HTMLDivElement>(null)
  useEscapeKey(onDismiss)
  useEffect(() => { overlayRef.current?.focus() }, [])

  return (
    <div
      ref={overlayRef}
      tabIndex={-1}
      className="fixed inset-0 z-50 overflow-hidden bg-black/90 flex flex-col items-center justify-center"
      onClick={onDismiss}
      role="dialog"
      aria-modal="true"
      aria-label="Majadu 1st Anniversary"
    >
      {/* Light rays — rotating conic gradient behind everything */}
      <div
        className="absolute pointer-events-none"
        aria-hidden="true"
        style={{
          width: '160vw',
          height: '160vw',
          top: '-40vw',
          left: '50%',
          background: 'repeating-conic-gradient(rgba(227,179,65,0.07) 0deg, rgba(227,179,65,0.07) 7deg, transparent 7deg, transparent 20deg)',
          animation: 'annivRaySpin 16s linear infinite',
          zIndex: 1,
        }}
      />

      {/* Gold sparkle particles */}
      <div className="absolute inset-0 pointer-events-none" aria-hidden="true" style={{ zIndex: 2 }}>
        {SPARKLES.map((s) => (
          <div
            key={s.id}
            className="absolute"
            style={{
              left: s.left,
              bottom: s.bottom,
              width: s.size,
              height: s.size,
              background: s.color,
              transform: 'rotate(45deg)',
              borderRadius: '1px',
              boxShadow: `0 0 ${s.size * 2}px ${s.color}`,
              animation: `annivSparkleFloat ${s.duration} ${s.delay} ease-in infinite`,
            }}
          />
        ))}
      </div>

      {/* Anniversary logo — slides down from top */}
      <div
        className="pointer-events-none relative flex justify-center px-6"
        style={{ animation: 'annivSlideInTop 0.6s 0.3s ease-out both', zIndex: 20 }}
      >
        <img
          src="/anniv-top.png"
          alt="Majadu 1st Anniversary"
          className="w-full max-w-lg object-contain drop-shadow-2xl"
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
      </div>

      {/* Side players row */}
      <div className="pointer-events-none relative flex w-full items-end justify-between flex-1" style={{ zIndex: 10 }}>
        <img
          src="/anniv-left.png"
          alt=""
          aria-hidden="true"
          className="object-contain object-bottom"
          style={{ height: '55vh', maxWidth: '45vw', animation: 'annivSlideInLeft 0.7s 0s ease-out both' }}
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
        <img
          src="/anniv-right.png"
          alt=""
          aria-hidden="true"
          className="object-contain object-bottom"
          style={{ height: '55vh', maxWidth: '45vw', animation: 'annivSlideInRight 0.7s 0s ease-out both' }}
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
      </div>

      {/* Team lineup logos — fades up in center */}
      <div
        className="pointer-events-none absolute inset-x-0 flex justify-center px-8"
        style={{ animation: 'annivFadeInUp 0.7s 0.6s ease-out both', zIndex: 20 }}
      >
        <img
          src="/anniv-center.png"
          alt="Team lineup"
          className="w-full max-w-sm object-contain drop-shadow-xl"
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
      </div>
    </div>
  )
}
