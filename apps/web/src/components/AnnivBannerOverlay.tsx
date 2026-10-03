import { useRef, useEffect } from 'react'
import { useEscapeKey } from '../hooks/useEscapeKey'

interface AnnivBannerOverlayProps {
  onDismiss(): void
}

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
      {/* Anniversary logo — slides down from top */}
      <div
        className="pointer-events-none relative z-20 flex justify-center px-6"
        style={{ animation: 'annivSlideInTop 0.6s 0.3s ease-out both' }}
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
      <div className="pointer-events-none relative z-10 flex w-full items-end justify-between flex-1">
        {/* Left player group */}
        <img
          src="/anniv-left.png"
          alt=""
          aria-hidden="true"
          className="object-contain object-bottom"
          style={{ height: '55vh', maxWidth: '45vw', animation: 'annivSlideInLeft 0.7s 0s ease-out both' }}
          draggable={false}
          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none' }}
        />
        {/* Right player group */}
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
        className="pointer-events-none absolute inset-x-0 z-20 flex justify-center px-8"
        style={{ animation: 'annivFadeInUp 0.7s 0.6s ease-out both' }}
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
