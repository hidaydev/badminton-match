interface Props {
  isIos: boolean
  onInstall(): void
  onClose(): void
}

export default function InstallModal({ isIos, onInstall, onClose }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-full max-w-lg bg-slate-900 border border-slate-700 rounded-t-3xl p-6 pb-10 flex flex-col gap-5">
        <div className="w-10 h-1 bg-slate-700 rounded-full mx-auto" />

        <div className="flex flex-col gap-1">
          <h2 className="text-lg font-bold text-white">Install Majadu App</h2>
          <p className="text-sm text-slate-400">
            {isIos
              ? 'Follow these steps to add to your home screen:'
              : 'Add to your home screen for quick access — works offline too.'}
          </p>
        </div>

        {isIos ? (
          <ol className="flex flex-col gap-3">
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">1.</span>
              <span className="text-sm text-slate-300">
                Tap the <span className="font-semibold text-white">Share</span> button{' '}
                <span className="inline-block text-base">⬆️</span> in Safari's toolbar at the bottom of the screen.
              </span>
            </li>
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">2.</span>
              <span className="text-sm text-slate-300">
                Scroll down and tap{' '}
                <span className="font-semibold text-white">"Add to Home Screen"</span>.
              </span>
            </li>
            <li className="flex items-start gap-3">
              <span className="text-xl shrink-0">3.</span>
              <span className="text-sm text-slate-300">
                Tap <span className="font-semibold text-white">"Add"</span> to confirm.
              </span>
            </li>
          </ol>
        ) : null}

        <div className="flex flex-col gap-2 pt-1">
          {!isIos && (
            <button
              onClick={onInstall}
              className="w-full py-3 rounded-xl bg-yellow-400 text-slate-950 font-bold text-sm active:scale-[0.98] transition-transform"
            >
              Install
            </button>
          )}
          <button
            onClick={onClose}
            className="w-full py-3 rounded-xl bg-slate-800 text-slate-300 font-medium text-sm active:scale-[0.98] transition-transform"
          >
            {isIos ? 'Got it' : 'Not now'}
          </button>
        </div>
      </div>
    </div>
  )
}
