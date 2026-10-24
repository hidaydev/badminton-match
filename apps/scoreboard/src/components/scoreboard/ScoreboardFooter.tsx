import { ScoreboardControls } from './ScoreboardControls'

export interface ScoreboardFooterProps {
  isFullscreen: boolean
  onReset: () => void
  onSwap: () => void
  onToggleFullscreen: () => void
}

export function ScoreboardFooter({
  isFullscreen,
  onReset,
  onSwap,
  onToggleFullscreen,
}: ScoreboardFooterProps) {
  return (
    <div
      className="fixed bottom-0 left-0 right-0 flex items-center justify-center gap-4 z-20 pointer-events-none"
      style={{
        paddingTop: '0.5rem',
        paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))',
      }}
    >
      <ScoreboardControls
        isFullscreen={isFullscreen}
        onReset={onReset}
        onSwap={onSwap}
        onToggleFullscreen={onToggleFullscreen}
        buttonClassName="px-3 py-1"
      />
    </div>
  )
}
