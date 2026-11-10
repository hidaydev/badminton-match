// src/components/Icon.tsx — one 24px stroke set, `currentColor` only.
// Every glyph in the app lives here; a screen that draws its own path gets a
// different stroke weight next to this one and is the thing DS-22 was about.
import type { SVGProps } from 'react'

export type IconName =
  | 'plus' | 'sessions' | 'history' | 'ratings' | 'scoreboard' | 'tournament'
  | 'admin' | 'post' | 'download' | 'download-tray' | 'play' | 'unlock' | 'players'
  | 'season' | 'camera' | 'chevron-left' | 'chevron-right' | 'check' | 'close'
  | 'refresh' | 'sync' | 'rotate' | 'share' | 'trash' | 'user' | 'list'

export default function Icon({ name, size = 20, ...rest }: { name: IconName; size?: number } & SVGProps<SVGSVGElement>) {
  const common: SVGProps<SVGSVGElement> = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.8,
    strokeLinecap: 'round',
    strokeLinejoin: 'round',
    'aria-hidden': true,
    ...rest,
  }
  switch (name) {
    case 'plus':
      return <svg {...common}><path d="M12 5v14M5 12h14" /></svg>
    case 'sessions':
      return <svg {...common}><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3 6h.01M3 12h.01M3 18h.01" /></svg>
    case 'history':
      return <svg {...common}><circle cx="12" cy="8" r="4" /><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6" /></svg>
    case 'ratings':
      return <svg {...common}><path d="M4 19v-8M10 19V9M16 19V5" /><path d="M2 19h20" /></svg>
    case 'scoreboard':
      return <svg {...common}><rect x="3" y="5" width="18" height="14" rx="1" /><path d="M8 3v4M16 3v4M3 12h18" /><path d="M7 15l2-2 2 2 2-2 2 2" /></svg>
    case 'tournament':
      return <svg {...common}><path d="M8 21h8M12 17v4M7 4h10v4a5 5 0 0 1-10 0V4z" /><path d="M7 6H3v2a3 3 0 0 0 4 2.8M17 6h4v2a3 3 0 0 1-4 2.8" /></svg>
    case 'admin':
      return <svg {...common}><path d="M12 3l7 3v5c0 4.5-3 8-7 10-4-2-7-5.5-7-10V6l7-3z" /><path d="M9.5 12l2 2 3-3.5" /></svg>
    case 'post':
      return <svg {...common}><rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><path d="M21 15l-5-5L5 21" /></svg>
    case 'download':
      return <svg {...common}><path d="M12 3v12M7 10l5 5 5-5" /><path d="M4 21h16" /></svg>
    case 'download-tray':
      return <svg {...common}><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="M7 10l5 5 5-5" /><path d="M12 15V3" /></svg>
    case 'play':
      return <svg {...common}><path d="M6 4l14 8-14 8V4z" /></svg>
    case 'unlock':
      return <svg {...common}><rect x="4" y="11" width="16" height="10" rx="1" /><path d="M8 11V7a4 4 0 0 1 7.9-1" /></svg>
    case 'players':
      return <svg {...common}><circle cx="9" cy="8" r="3.5" /><path d="M3 20c0-3.3 2.7-5 6-5s6 1.7 6 5" /><path d="M16 4.5a3.5 3.5 0 0 1 0 7M18.5 15.5c1.6.8 2.5 2 2.5 4.5" /></svg>
    case 'season':
      return <svg {...common}><rect x="3" y="5" width="18" height="16" rx="1" /><path d="M8 3v4M16 3v4M3 10h18" /></svg>
    case 'camera':
      return <svg {...common}><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z" /><circle cx="12" cy="13" r="4" /></svg>
    case 'chevron-left':
      return <svg {...common}><path d="M15 18l-6-6 6-6" /></svg>
    case 'chevron-right':
      return <svg {...common}><path d="M9 18l6-6-6-6" /></svg>
    case 'check':
      return <svg {...common}><path d="M20 6L9 17l-5-5" /></svg>
    case 'close':
      return <svg {...common}><path d="M18 6L6 18M6 6l12 12" /></svg>
    case 'refresh':
      return <svg {...common}><path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8" /><path d="M21 3v5h-5" /></svg>
    case 'sync':
      return <svg {...common}><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" /><path d="M21 3v5h-5" /><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" /><path d="M8 16H3v5" /></svg>
    case 'rotate':
      return <svg {...common}><path d="M21 2v6h-6" /><path d="M3 12a9 9 0 0 1 15-6.7L21 8" /><path d="M3 22v-6h6" /><path d="M21 12a9 9 0 0 1-15 6.7L3 16" /></svg>
    case 'share':
      return <svg {...common}><circle cx="18" cy="5" r="3" /><circle cx="6" cy="12" r="3" /><circle cx="18" cy="19" r="3" /><path d="M8.59 13.51l6.83 3.98M15.41 6.51L8.59 10.49" /></svg>
    case 'trash':
      return <svg {...common}><path d="M3 6h18" /><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6" /><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2" /></svg>
    case 'user':
      return <svg {...common}><circle cx="12" cy="8" r="4" /><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6" /></svg>
    case 'list':
      return <svg {...common}><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3 6h.01M3 12h.01M3 18h.01" /></svg>
    default:
      return null
  }
}
