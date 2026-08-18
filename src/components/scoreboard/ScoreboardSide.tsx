import type { MouseEvent, KeyboardEvent } from 'react'

const SIDE_CONFIG = {
  red: {
    bg: '#b91c1c',
    minusPosition: 'right-4' as const,
    placeholder: 'RED',
    decreaseLabel: 'Decrease red score',
    nameLabel: 'Red team name',
  },
  blue: {
    bg: '#1d4ed8',
    minusPosition: 'left-4' as const,
    placeholder: 'BLUE',
    decreaseLabel: 'Decrease blue score',
    nameLabel: 'Blue team name',
  },
} as const

export interface ScoreboardSideProps {
  side: 'red' | 'blue'
  score: number
  displayName: string
  editValue: string
  isEditing: boolean
  isPop: boolean
  isOverlay: boolean
  onScore: () => void
  onMinus: (e: MouseEvent) => void
  onNameChange: (value: string) => void
  onStartEditing: () => void
  onStopEditing: () => void
}

export function ScoreboardSide({
  side,
  score,
  displayName,
  editValue,
  isEditing,
  isPop,
  isOverlay,
  onScore,
  onMinus,
  onNameChange,
  onStartEditing,
  onStopEditing,
}: ScoreboardSideProps) {
  const config = SIDE_CONFIG[side]

  return (
    <div
      className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 duration-75"
      style={{ background: config.bg, transitionProperty: 'filter' }}
      onClick={onScore}
      role="button"
      tabIndex={0}
      onKeyDown={(e: KeyboardEvent) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onScore() } }}
    >
      {/* Player name */}
      <div className="absolute top-0 left-0 right-0 flex justify-center pt-5" onClick={e => e.stopPropagation()}>
        {isOverlay ? (
          <span
            className="uppercase font-bold text-white truncate px-4 py-1 rounded-full pointer-events-none"
            style={{ background: 'rgba(0,0,0,0.25)', fontSize: 'clamp(0.75rem,2.2vmax,1rem)', letterSpacing: '0.12em' }}
          >
            {displayName}
          </span>
        ) : isEditing ? (
          <input
            autoFocus
            placeholder={config.placeholder}
            value={editValue}
            onChange={e => onNameChange(e.target.value)}
            onBlur={onStopEditing}
            onKeyDown={e => { if (e.key === 'Enter') onStopEditing() }}
            className="bg-transparent text-center text-white/70 font-bold uppercase outline-none border-b border-white/30 w-36"
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
            aria-label={config.nameLabel}
          />
        ) : (
          <span
            className={`uppercase font-bold cursor-text border-b border-transparent hover:border-white/20 transition-colors ${editValue ? 'text-white/50' : 'text-white/30'}`}
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
            onClick={onStartEditing}
          >
            {displayName}
          </span>
        )}
      </div>

      {/* Score */}
      <span
        className="text-white font-black font-mono leading-none pointer-events-none"
        style={{
          fontSize: 'clamp(6rem, 22vmax, 13rem)',
          transform: isPop ? 'scale(1.1)' : 'scale(1)',
          transition: 'transform 0.08s ease-out',
        }}
      >
        {score}
      </span>
      <span
        className="text-white/20 tracking-widest mt-3 pointer-events-none"
        style={{ fontSize: 'clamp(0.55rem,1.2vmax,0.75rem)' }}
      >
        tap to score
      </span>

      <button
        onClick={onMinus}
        className={`absolute ${config.minusPosition} top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors`}
        style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
        aria-label={config.decreaseLabel}
      >
        −
      </button>
    </div>
  )
}
