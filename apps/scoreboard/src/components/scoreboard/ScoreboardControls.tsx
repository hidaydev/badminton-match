export interface ScoreboardControlsProps {
  isFullscreen: boolean
  onReset: () => void
  onSwap: () => void
  onToggleFullscreen: () => void
  /** Tailwind classes for button sizing. Defaults to overlay-style h-9 layout. */
  buttonClassName?: string
}

const baseBtnClass = 'rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto'
const baseBtnStyle = { background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' } as const

export function ScoreboardControls({
  isFullscreen,
  onReset,
  onSwap,
  onToggleFullscreen,
  buttonClassName = 'px-3 h-9 flex items-center',
}: ScoreboardControlsProps) {
  const cls = `${buttonClassName} ${baseBtnClass}`

  return (
    <>
      <button
        onClick={onReset}
        className={cls}
        style={baseBtnStyle}
        aria-label="Reset scores"
      >
        ↺
      </button>
      <button
        onClick={onSwap}
        className={cls}
        style={baseBtnStyle}
        aria-label="Swap sides"
      >
        ⇄
      </button>
      <button
        onClick={onToggleFullscreen}
        className={cls}
        style={baseBtnStyle}
        aria-label={isFullscreen ? 'Exit fullscreen' : 'Enter fullscreen'}
      >
        {isFullscreen ? '⊠' : '⛶'}
      </button>
    </>
  )
}
