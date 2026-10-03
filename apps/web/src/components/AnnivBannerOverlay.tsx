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

const FW_COLORS = ['#e3b341', '#f5d278', '#ffffff', '#ff9f43', '#a8edea', '#fd79a8', '#e8cd83']

const BURSTS = Array.from({ length: 7 }, (_, b) => ({
  id: b,
  left: `${12 + (b * 13 + Math.sin(b * 2) * 9) % 76}%`,
  top:  `${10 + (b * 11 + Math.cos(b * 1.7) * 7) % 55}%`,
  delay: `${((b * 1.1) % 5).toFixed(1)}s`,
  duration: '2.8s',
  flashColor: FW_COLORS[b % FW_COLORS.length],
  particles: Array.from({ length: 14 }, (_, p) => {
    const angle = (p / 14) * Math.PI * 2
    const dist  = 30 + (p % 5) * 14
    return {
      id: p,
      tx: Math.cos(angle) * dist,
      ty: Math.sin(angle) * dist,
      color: FW_COLORS[(b * 3 + p) % FW_COLORS.length],
      size: 3 + (p % 3) * 2,
    }
  }),
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
          width: '200vmax',
          height: '200vmax',
          top: '-50vmax',
          left: '50%',
          background: 'repeating-conic-gradient(rgba(227,179,65,0.07) 0deg, rgba(227,179,65,0.07) 7deg, transparent 7deg, transparent 20deg)',
          animation: 'annivRaySpin 16s linear infinite',
          zIndex: 1,
        }}
      />

      {/* Fireworks */}
      <div className="absolute inset-0 pointer-events-none" aria-hidden="true" style={{ zIndex: 3 }}>
        {BURSTS.map((burst) => (
          <div key={burst.id} className="absolute" style={{ left: burst.left, top: burst.top }}>
            {/* Flash at center */}
            <div style={{
              position: 'absolute',
              width: 10, height: 10,
              borderRadius: '50%',
              background: burst.flashColor,
              boxShadow: `0 0 12px 4px ${burst.flashColor}`,
              transform: 'translate(-50%, -50%)',
              animation: `annivFireworkFlash ${burst.duration} ${burst.delay} ease-out infinite backwards`,
            }} />
            {/* Particles */}
            {burst.particles.map((p) => (
              <div key={p.id} style={{
                position: 'absolute',
                width: p.size, height: p.size,
                borderRadius: '50%',
                background: p.color,
                boxShadow: `0 0 ${p.size * 2}px ${p.color}`,
                transform: 'translate(-50%, -50%)',
                ['--fw-tx' as string]: `${p.tx}px`,
                ['--fw-ty' as string]: `${p.ty}px`,
                animation: `annivFireworkBurst ${burst.duration} ${burst.delay} ease-out infinite backwards`,
              }} />
            ))}
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
      <div className="pointer-events-none relative flex w-full items-end justify-between flex-1" style={{ zIndex: 10, isolation: 'isolate' }}>
        <div className="anniv-left" style={{ height: '65vh', animation: 'annivSlideInLeft 0.7s 0s ease-out both', marginLeft: '-20%' }}>
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
        <div className="anniv-right" style={{ height: '65vh', animation: 'annivSlideInRight 0.7s 0s ease-out both', marginRight: '-10%' }}>
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

      {/* Tap to dismiss */}
      <p
        className="pointer-events-none absolute bottom-6 inset-x-0 text-center text-[11px] uppercase tracking-widest text-white/30 font-sans"
        style={{ zIndex: 30, animation: 'annivBlink 3s ease-in-out infinite' }}
      >
        Tap anywhere to dismiss
      </p>

    </div>
  )
}
