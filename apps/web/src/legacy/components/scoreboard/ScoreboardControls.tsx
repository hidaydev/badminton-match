import { t } from '../../../i18n'

export interface ScoreboardControlsProps {
  isFullscreen: boolean
  onReset: () => void
  onSwap: () => void
  onToggleFullscreen: () => void
  /** Tailwind classes for button sizing. Defaults to the 44px overlay layout. */
  buttonClassName?: string
}

const baseBtnClass = 'rounded-lg text-white/90 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto'
const baseBtnStyle = { background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' } as const

export function ScoreboardControls({
  isFullscreen,
  onReset,
  onSwap,
  onToggleFullscreen,
  buttonClassName = 'px-3 min-w-11 h-11 flex items-center justify-center',
}: ScoreboardControlsProps) {
  const cls = `${buttonClassName} ${baseBtnClass}`

  return (
    <>
      <button
        onClick={onReset}
        className={`${cls} hit44`}
        style={baseBtnStyle}
        aria-label={t('scoreboard.reset')}
      >
        ↺
      </button>
      <button
        onClick={onSwap}
        className={`${cls} hit44`}
        style={baseBtnStyle}
        aria-label={t('scoreboard.swap')}
      >
        ⇄
      </button>
      <button
        onClick={onToggleFullscreen}
        className={`${cls} hit44`}
        style={baseBtnStyle}
        aria-label={isFullscreen ? t('scoreboard.fullscreenExit') : t('scoreboard.fullscreenEnter')}
      >
        {isFullscreen ? '⊠' : '⛶'}
      </button>
    </>
  )
}
