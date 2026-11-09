import { memo } from 'react'
import type { ScoreboardSideProps } from './types'

const SIDE_BACKGROUND = {
  red: '#b91c1c',
  blue: '#1d4ed8',
} as const

const MINUS_POSITION = {
  red: 'right-4',
  blue: 'left-4',
} as const

export const ScoreboardSide = memo(function ScoreboardSide({
  side,
  labels,
  score,
  displayName,
  editValue,
  isEditing,
  isPop,
  isOverlay,
  readOnly = false,
  onScore,
  onMinus,
  onNameChange,
  onStartEditing,
  onStopEditing,
}: ScoreboardSideProps) {
  return (
    <div
      className="flex-1 flex flex-col items-center justify-center relative"
      style={{ background: SIDE_BACKGROUND[side] }}
    >
      {/* Player name */}
      <div className="absolute top-0 left-0 right-0 flex justify-center pt-5">
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
            placeholder={labels.placeholder}
            value={editValue}
            onChange={e => onNameChange(e.target.value)}
            onBlur={onStopEditing}
            onKeyDown={e => { if (e.key === 'Enter') onStopEditing() }}
            className="bg-transparent text-center text-white/90 font-bold uppercase outline-none border-b border-white/30 w-36"
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
            aria-label={labels.teamName}
          />
        ) : (
          <span
            className={`uppercase font-bold border-b border-transparent transition-colors ${readOnly ? 'text-white/80 cursor-default' : `cursor-text hover:border-white/20 ${editValue ? 'text-white/90' : 'text-white/80'}`}`}
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
            onClick={readOnly ? undefined : onStartEditing}
          >
            {displayName}
          </span>
        )}
      </div>

      {/* Score face. This is a real button rather than a role="button" wrapper:
          it is the only control that adds a point, so keydown from the name
          field and the minus button can never reach it. */}
      <button
        type="button"
        onClick={onScore}
        disabled={readOnly}
        aria-label={labels.score(displayName, score)}
        className={`score-face w-full flex-1 flex flex-col items-center justify-center duration-75 ${readOnly ? 'cursor-default' : 'cursor-pointer active:brightness-150'}`}
        style={{ transitionProperty: 'filter' }}
      >
        <span
          aria-hidden="true"
          className="text-white font-black font-sans leading-none pointer-events-none"
          style={{
            fontSize: 'clamp(6rem, 22vmax, 13rem)',
            transform: isPop ? 'scale(1.1)' : 'scale(1)',
            transition: 'transform 0.08s ease-out',
          }}
        >
          {score}
        </span>
        <span
          aria-hidden="true"
          className="text-white/80 tracking-widest mt-3 pointer-events-none"
          style={{ fontSize: 'clamp(0.55rem,1.2vmax,0.75rem)' }}
        >
          {/* The leading space is structural: axe joins adjacent text nodes
              without a separator, so without it the visible text reads
              "0tap to score" and no longer appears inside the label. */}
          {' '}{labels.tapToScore}
        </span>
      </button>

      <button
        type="button"
        onClick={onMinus}
        disabled={readOnly}
        className={`absolute ${MINUS_POSITION[side]} top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/90 transition-colors ${readOnly ? 'cursor-default' : 'cursor-pointer active:bg-black/40'}`}
        style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
        aria-label={labels.decrease}
      >
        −
      </button>
    </div>
  )
})
