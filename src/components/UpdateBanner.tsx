interface UpdateBannerProps {
  onReload(): void
  onDismiss(): void
}

export default function UpdateBanner({ onReload, onDismiss }: UpdateBannerProps) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center"
      onClick={onDismiss}
      role="dialog"
      aria-modal="true"
      aria-label="Update available"
    >
      <div className="absolute inset-0 bg-black/70 backdrop-blur-sm" />

      <div
        className="relative w-full max-w-lg bg-slate-900 rounded-t-3xl flex flex-col overflow-hidden
          animate-[slideUp_0.3s_ease-out]"
        onClick={(e) => e.stopPropagation()}
        style={{ paddingBottom: 'env(safe-area-inset-bottom, 24px)' }}
      >
        {/* Handle */}
        <div className="flex justify-center pt-3 pb-1">
          <div className="w-10 h-1 bg-slate-700 rounded-full" />
        </div>

        {/* Icon + heading */}
        <div className="flex flex-col items-center gap-2 px-6 pt-4 pb-5">
          <div className="w-14 h-14 rounded-lg bg-amber-400/10 border border-amber-400/20 flex items-center justify-center text-3xl">
            🚀
          </div>
          <div className="text-center">
            <p className="text-white font-bold text-lg leading-tight">Update Available</p>
            <p className="text-slate-400 text-sm mt-0.5">A new version of Majadu is ready</p>
          </div>
        </div>

        <div className="h-px bg-slate-800 mx-6" />

        {/* What's new hint */}
        <div className="flex items-start gap-4 px-6 py-5">
          <div className="shrink-0 w-8 h-8 rounded-full bg-elevated flex items-center justify-center text-[1rem]">✨</div>
          <div className="flex flex-col gap-0.5 pt-0.5">
            <span className="text-sm font-semibold text-white">Improvements & fixes</span>
            <span className="text-xs text-slate-400">Reload to get the latest version</span>
          </div>
        </div>

        <div className="h-px bg-slate-800 mx-6" />

        {/* Actions */}
        <div className="flex flex-col gap-2 px-6 pt-4 pb-2">
          <button
            onClick={onReload}
            className="w-full py-3.5 rounded-lg bg-yellow-400 text-slate-950 font-bold text-sm
              active:scale-98 transition-transform"
          >
            Reload Now
          </button>
          <button
            onClick={onDismiss}
            className="w-full py-3 rounded-lg text-slate-400 font-medium text-sm
              active:scale-98 transition-transform"
          >
            Later
          </button>
        </div>
      </div>
    </div>
  )
}
