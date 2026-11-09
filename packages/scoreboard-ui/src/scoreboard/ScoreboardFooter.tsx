import type { CSSProperties, ReactNode } from 'react'
import { ScoreboardControls } from './ScoreboardControls'
import type { OverlayFooterState, ScoreboardLabels } from './types'

export interface ScoreboardFooterProps {
  labels: ScoreboardLabels
  isFullscreen: boolean
  onReset: () => void
  onSwap: () => void
  onToggleFullscreen: () => void
  /** Standalone mode: export the match as text. */
  onExport?: () => void
  /** Provide for overlay mode. Omit for standalone mode. */
  overlay?: OverlayFooterState
  /** Standalone mode only: navigate back. */
  onBack?: () => void
  /** Accent colour for the overlay save button. */
  accentColor?: string
}

const FOOTER_STYLE: CSSProperties = {
  paddingTop: '0.5rem',
  paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))',
}

export function ScoreboardFooter({
  labels,
  isFullscreen,
  onReset,
  onSwap,
  onToggleFullscreen,
  onExport,
  overlay,
  onBack,
  accentColor = '#e3b341',
}: ScoreboardFooterProps) {
  const exportControl: ReactNode = onExport ? (
    <button
      type="button"
      onClick={onExport}
      className="px-3 py-1 rounded-lg text-white/90 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
      style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
      aria-label={labels.exportMatch}
    >
      ⤓
    </button>
  ) : undefined

  return (
    <div
      className="fixed bottom-0 left-0 right-0 flex items-center justify-center gap-4 z-20 pointer-events-none"
      style={FOOTER_STYLE}
    >
      {overlay ? (
        overlay.pendingClose ? (
          <>
            <span className="text-white/80 text-xs pointer-events-auto">{labels.discardPrompt}</span>
            <button
              type="button"
              onClick={overlay.onDiscard}
              className="px-4 min-h-11 inline-flex items-center rounded-lg text-white/80 text-sm cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.12)', border: '1px solid rgba(255,255,255,0.2)' }}
            >
              {labels.discard}
            </button>
            <button
              type="button"
              onClick={overlay.onKeepScoring}
              className="px-4 min-h-11 inline-flex items-center rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto"
              style={{ background: accentColor }}
            >
              {labels.keepScoring}
            </button>
          </>
        ) : (
          <>
            <button
              type="button"
              onClick={overlay.onClose}
              disabled={overlay.isSaving}
              className="px-3 min-w-11 h-11 flex items-center justify-center rounded-lg text-white/90 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto disabled:opacity-30 disabled:cursor-not-allowed"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
              aria-label={labels.close}
            >
              ✕
            </button>
            <ScoreboardControls
              labels={labels}
              isFullscreen={isFullscreen}
              onReset={onReset}
              onSwap={onSwap}
              onToggleFullscreen={onToggleFullscreen}
            />
            <button
              type="button"
              onClick={overlay.onSave}
              disabled={overlay.isSaving}
              className="px-4 h-11 flex items-center rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto disabled:opacity-50 disabled:cursor-not-allowed"
              style={{ background: accentColor }}
            >
              {overlay.isSaving ? (
                <>
                  <svg className="animate-spin w-3.5 h-3.5 mr-1.5 shrink-0" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                  {labels.saving}
                </>
              ) : labels.save}
            </button>
          </>
        )
      ) : (
        <>
          {onBack && (
            <button
              type="button"
              onClick={onBack}
              className="px-3 min-w-11 h-11 flex items-center justify-center rounded-lg text-white/90 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
              aria-label={labels.home}
            >
              ←
            </button>
          )}
          <ScoreboardControls
            labels={labels}
            isFullscreen={isFullscreen}
            onReset={onReset}
            onSwap={onSwap}
            onToggleFullscreen={onToggleFullscreen}
            extra={exportControl}
            buttonClassName={
              onBack
                ? 'px-3 min-w-11 h-11 flex items-center justify-center'
                : 'px-3 py-1 min-w-11 h-11 flex items-center justify-center'
            }
          />
        </>
      )}
    </div>
  )
}
