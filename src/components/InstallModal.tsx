interface Props {
  isIos: boolean
  onInstall(): void
  onClose(): void
}

export default function InstallModal({ isIos, onInstall, onClose }: Props) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center"
      onClick={onClose}
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

        {/* App identity */}
        <div className="flex flex-col items-center gap-2 px-6 pt-4 pb-5">
          <img src="/logo.png" alt="Majadu" className="w-16 h-16 rounded-2xl object-contain" />
          <div className="text-center">
            <p className="text-white font-bold text-lg leading-tight">Install Majadu App</p>
            <p className="text-slate-400 text-sm mt-0.5">
              {isIos ? 'Add to your home screen in a few steps' : 'Get quick access right from your home screen'}
            </p>
          </div>
        </div>

        {/* Divider */}
        <div className="h-px bg-slate-800 mx-6" />

        {/* iOS steps */}
        {isIos ? (
          <ol className="flex flex-col gap-0 px-6 py-4">
            <li className="flex items-start gap-4 py-3">
              <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-base">⬆️</div>
              <div className="flex flex-col gap-0.5 pt-0.5">
                <span className="text-sm font-semibold text-white">Tap the Share button</span>
                <span className="text-xs text-slate-500">In Safari's toolbar at the bottom</span>
              </div>
            </li>
            <li className="flex flex-col gap-2 py-3">
              <div className="flex items-start gap-4">
                <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-base">➕</div>
                <div className="flex flex-col gap-0.5 pt-0.5">
                  <span className="text-sm font-semibold text-white">Tap "Add to Home Screen"</span>
                  <span className="text-xs text-slate-500">Scroll down in the share sheet</span>
                </div>
              </div>
              <img
                src="/add-to-home-screen.jpeg"
                alt="Add to Home Screen button"
                className="w-2/3 rounded-xl object-contain border border-slate-700 m-3"
              />
            </li>
            <li className="flex items-start gap-4 py-3">
              <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-base">✅</div>
              <div className="flex flex-col gap-0.5 pt-0.5">
                <span className="text-sm font-semibold text-white">Tap "Add" to confirm</span>
                <span className="text-xs text-slate-500">The app will appear on your home screen</span>
              </div>
            </li>
          </ol>
        ) : (
          <div className="flex items-start gap-4 px-6 py-5">
            <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-base">📲</div>
            <div className="flex flex-col gap-1 pt-0.5">
              <span className="text-sm font-semibold text-white">One tap to install</span>
              <span className="text-xs text-slate-500">Works offline · Fast · No app store needed</span>
            </div>
          </div>
        )}

        {/* Divider */}
        <div className="h-px bg-slate-800 mx-6" />

        {/* Actions */}
        <div className="flex flex-col gap-2 px-6 pt-4 pb-2">
          {!isIos && (
            <button
              onClick={onInstall}
              className="w-full py-3.5 rounded-2xl bg-yellow-400 text-slate-950 font-bold text-sm
                active:scale-[0.98] transition-transform"
            >
              Install App
            </button>
          )}
          <button
            onClick={onClose}
            className="w-full py-3 rounded-2xl text-slate-500 font-medium text-sm
              active:scale-[0.98] transition-transform"
          >
            {isIos ? 'Got it' : 'Not now'}
          </button>
        </div>
      </div>
    </div>
  )
}
