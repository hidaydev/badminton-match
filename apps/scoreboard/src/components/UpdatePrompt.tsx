export interface UpdatePromptProps {
  onUpdate: () => void
  onDismiss: () => void
}

export default function UpdatePrompt({ onUpdate, onDismiss }: UpdatePromptProps) {
  return (
    <div
      role="status"
      aria-live="polite"
      className="fixed bottom-14 left-1/2 -translate-x-1/2 z-40 flex items-center gap-3 px-4 py-2 rounded-xl text-xs text-white/80"
      style={{ background: 'rgba(0,0,0,0.85)', border: '1px solid rgba(255,255,255,0.15)' }}
    >
      <span>A new version is available</span>
      <button
        type="button"
        onClick={onUpdate}
        className="px-3 py-1 rounded-lg font-semibold text-white cursor-pointer"
        style={{ background: 'rgba(255,255,255,0.16)' }}
      >
        Reload
      </button>
      <button
        type="button"
        onClick={onDismiss}
        className="px-2 py-1 text-white/50 cursor-pointer"
      >
        Later
      </button>
    </div>
  )
}
