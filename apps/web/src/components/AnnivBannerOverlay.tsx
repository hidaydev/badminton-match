import { useRef, useEffect, useState } from 'react'
import { useEscapeKey } from '../hooks/useEscapeKey'

interface AnnivBannerOverlayProps {
  onDismiss(): void
}

const TARGET = new Date('2026-10-10T00:00:00+07:00').getTime()

function getTimeLeft() {
  const diff = Math.max(0, TARGET - Date.now())
  return {
    days:    Math.floor(diff / 86_400_000),
    hours:   Math.floor((diff % 86_400_000) / 3_600_000),
    minutes: Math.floor((diff % 3_600_000)  / 60_000),
    seconds: Math.floor((diff % 60_000)     / 1_000),
  }
}

const STARS = Array.from({ length: 20 }, (_, i) => ({
  id: i,
  top: `${(i * 7 + Math.sin(i) * 8) % 60}%`,
  left: `${20 + (i * 4.3 + Math.cos(i) * 12) % 75}%`,
  width: 1.5 + (i % 3) * 0.5,
  length: 60 + (i % 5) * 30,
  angle: -35 - (i % 4) * 8,
  delay: `-${((i * 0.6) % 5).toFixed(2)}s`,
  duration: `${1.2 + (i % 4) * 0.4}s`,
  color: ['#ffffff', '#e3b341', '#f5d278', '#ffffff', '#e8cd83'][i % 5],
}))

function CountdownUnit({ value, label }: { value: number; label: string }) {
  return (
    <div className="flex flex-col items-center gap-0.5">
      <div
        className="text-3xl font-bold tabular-nums leading-none"
        style={{ color: '#e3b341', textShadow: '0 0 20px rgba(227,179,65,0.6)' }}
      >
        {String(value).padStart(2, '0')}
      </div>
      <div className="text-[9px] uppercase tracking-widest text-white/50 font-sans">{label}</div>
    </div>
  )
}

export default function AnnivBannerOverlay({ onDismiss }: AnnivBannerOverlayProps) {
  const overlayRef = useRef<HTMLDivElement>(null)
  const [timeLeft, setTimeLeft] = useState(getTimeLeft)

  useEscapeKey(onDismiss)
  useEffect(() => { overlayRef.current?.focus() }, [])
  useEffect(() => {
    const id = setInterval(() => setTimeLeft(getTimeLeft()), 1000)
    return () => clearInterval(id)
  }, [])

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
      {/* Light rays */}
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

      {/* Shooting stars */}
      <div className="absolute inset-0 pointer-events-none" aria-hidden="true" style={{ zIndex: 2 }}>
        {STARS.map((s) => (
          /* Outer div: position + rotation; inner div: streak that travels along that axis */
          <div
            key={s.id}
            className="absolute"
            style={{ top: s.top, left: s.left, transform: `rotate(${s.angle}deg)` }}
          >
            <div
              style={{
                width: s.width,
                height: s.length,
                background: `linear-gradient(to bottom, ${s.color}, transparent)`,
                borderRadius: '999px',
                boxShadow: `0 0 4px ${s.color}`,
                animation: `annivShootingStar ${s.duration} ${s.delay} linear infinite`,
              }}
            />
          </div>
        ))}
      </div>

      {/* Anniversary logo */}
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

      {/* Countdown */}
      <div
        className="pointer-events-none relative flex flex-col items-center gap-1"
        style={{ animation: 'annivFadeInUp 0.6s 0.8s ease-out both', zIndex: 20 }}
      >
        <p className="text-[10px] uppercase tracking-[0.2em] text-white/40 font-sans mb-1">Coming in</p>
        <div className="flex items-start gap-4">
          <CountdownUnit value={timeLeft.days}    label="days" />
          <span className="text-2xl font-bold text-white/30 leading-none mt-0.5">:</span>
          <CountdownUnit value={timeLeft.hours}   label="hours" />
          <span className="text-2xl font-bold text-white/30 leading-none mt-0.5">:</span>
          <CountdownUnit value={timeLeft.minutes} label="min" />
          <span className="text-2xl font-bold text-white/30 leading-none mt-0.5">:</span>
          <CountdownUnit value={timeLeft.seconds} label="sec" />
        </div>
      </div>

      {/* Side players row */}
      <div className="pointer-events-none relative flex w-full items-end justify-between flex-1" style={{ zIndex: 10 }}>
        <div style={{ height: '65vh', animation: 'annivSlideInLeft 0.7s 0s ease-out both', marginLeft: '-20%' }}>
          <img
            src="/anniv-left.png"
            alt=""
            aria-hidden="true"
            style={{ height: '100%', width: 'auto' }}
            className="object-bottom"
            draggable={false}
            onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
          />
        </div>
        <div style={{ height: '65vh', animation: 'annivSlideInRight 0.7s 0s ease-out both', marginRight: '-10%' }}>
          <img
            src="/anniv-right.png"
            alt=""
            aria-hidden="true"
            style={{ height: '100%', width: 'auto' }}
            className="object-bottom"
            draggable={false}
            onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
          />
        </div>
      </div>

    </div>
  )
}
