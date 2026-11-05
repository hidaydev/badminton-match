import { ScoreboardControls } from './ScoreboardControls'

export interface OverlayFooterState {
  pendingClose: boolean
  isSaving: boolean
  onClose: () => void
  onSave: () => void
  onDiscard: () => void
  onKeepScoring: () => void
}

export interface ScoreboardFooterProps {
  isFullscreen: boolean
  onReset: () => void
  onSwap: () => void
  onToggleFullscreen: () => void
  /** Provide for overlay mode. Omit for standalone mode. */
  overlay?: OverlayFooterState
  /** Standalone mode only — navigate back. */
  onBack?: () => void
}

export function ScoreboardFooter({
  isFullscreen,
  onReset,
  onSwap,
  onToggleFullscreen,
  overlay,
  onBack,
}: ScoreboardFooterProps) {
  return (
    <div
      className="fixed bottom-0 left-0 right-0 flex items-center justify-center gap-4 z-20 pointer-events-none"
      style={{
        paddingTop: '0.5rem',
        paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))',
      }}
    >
      {overlay ? (
        overlay.pendingClose ? (
          <>
            <span className="text-white/50 text-xs pointer-events-auto">Discard score?</span>
            <button
              onClick={overlay.onDiscard}
              className="px-4 py-1 rounded-lg text-white/80 text-sm cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.12)', border: '1px solid rgba(255,255,255,0.2)' }}
            >
              Discard
            </button>
            <button
              onClick={overlay.onKeepScoring}
              className="px-4 py-1 rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto"
              style={{ background: '#fbbf24' }}
            >
              Keep scoring
            </button>
          </>
        ) : (
          <>
            <button
              onClick={overlay.onClose}
              disabled={overlay.isSaving}
              className="px-3 h-9 flex items-center rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto disabled:opacity-30 disabled:cursor-not-allowed"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
              aria-label="Close scoreboard"
            >
              ✕
            </button>
            <ScoreboardControls
              isFullscreen={isFullscreen}
              onReset={onReset}
              onSwap={onSwap}
              onToggleFullscreen={onToggleFullscreen}
            />
            <button
              onClick={overlay.onSave}
              disabled={overlay.isSaving}
              className="px-4 h-9 flex items-center rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto disabled:opacity-50 disabled:cursor-not-allowed"
              style={{ background: '#fbbf24' }}
            >
              {overlay.isSaving ? (
                <>
                  <svg className="animate-spin w-3.5 h-3.5 mr-1.5 shrink-0" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                  Saving…
                </>
              ) : 'Save Score'}
            </button>
          </>
        )
      ) : (
        <>
          <button
            onClick={onBack}
            className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
            style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
            aria-label="Back to home"
          >
            ←
          </button>
          <ScoreboardControls
            isFullscreen={isFullscreen}
            onReset={onReset}
            onSwap={onSwap}
            onToggleFullscreen={onToggleFullscreen}
            buttonClassName="px-3 py-1"
          />
        </>
      )}
    </div>
  )
}
