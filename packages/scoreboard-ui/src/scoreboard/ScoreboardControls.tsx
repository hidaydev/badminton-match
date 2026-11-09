import type { ReactNode } from 'react'
import type { ScoreboardLabels } from './types'

export interface ScoreboardControlsProps {
  labels: ScoreboardLabels
  isFullscreen: boolean
  onReset: () => void
  onSwap: () => void
  onToggleFullscreen: () => void
  /** Extra control rendered between swap and fullscreen. */
  extra?: ReactNode
  /** Tailwind classes for button sizing. Defaults to the 44px overlay layout. */
  buttonClassName?: string
}

const baseBtnClass = 'rounded-lg text-white/90 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto'
const baseBtnStyle = { background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' } as const

export function ScoreboardControls({
  labels,
  isFullscreen,
  onReset,
  onSwap,
  onToggleFullscreen,
  extra,
  buttonClassName = 'px-3 min-w-11 h-11 flex items-center justify-center',
}: ScoreboardControlsProps) {
  const cls = `${buttonClassName} ${baseBtnClass}`

  return (
    <>
      <button
        type="button"
        onClick={onReset}
        className={cls}
        style={baseBtnStyle}
        aria-label={labels.reset}
      >
        ↺
      </button>
      <button
        type="button"
        onClick={onSwap}
        className={cls}
        style={baseBtnStyle}
        aria-label={labels.swap}
      >
        ⇄
      </button>
      {extra}
      <button
        type="button"
        onClick={onToggleFullscreen}
        className={cls}
        style={baseBtnStyle}
        aria-label={isFullscreen ? labels.fullscreenExit : labels.fullscreenEnter}
      >
        {isFullscreen ? '⊠' : '⛶'}
      </button>
    </>
  )
}
