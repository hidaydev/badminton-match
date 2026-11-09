import { Overlay } from '@majadu/scoreboard-ui'

interface InstallModalProps {
  isIos: boolean
  /** True once the precache controls the page; the offline claim waits for it. */
  offlineReady?: boolean
  onInstall(): void
  onClose(): void
}

// The shared sheet owns the scrim, the focus trap, Escape and the safe area;
// this body only carries the install instructions.
export default function InstallModal({ isIos, offlineReady = false, onInstall, onClose }: InstallModalProps) {
  return (
    <Overlay onClose={onClose} title="Install app">
      <div className="flex flex-col items-center gap-2 pt-2 pb-5">
        <img src="/logo-192.png" alt="MAJADU Score" className="w-16 h-16 rounded-lg object-contain" />
        <div className="text-center">
          <p className="text-white font-bold text-lg leading-tight">Install MAJADU Score</p>
          <p className="text-slate-400 text-sm mt-0.5">
            {isIos ? 'Add to your home screen in a few steps' : 'Get quick access right from your home screen'}
          </p>
        </div>
      </div>

      <div className="h-px bg-slate-800" />

      {isIos ? (
        <ol className="flex flex-col gap-0 py-2">
          <li className="flex items-start gap-4 py-3">
            <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-[1rem]">⬆️</div>
            <div className="flex flex-col gap-0.5 pt-0.5">
              <span className="text-sm font-semibold text-white">Tap the Share button</span>
              <span className="text-xs text-slate-400">In Safari's toolbar at the bottom</span>
            </div>
          </li>
          <li className="flex flex-col gap-2 py-3">
            <div className="flex items-start gap-4">
              <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-[1rem]">➕</div>
              <div className="flex flex-col gap-0.5 pt-0.5">
                <span className="text-sm font-semibold text-white">Tap "Add to Home Screen"</span>
                <span className="text-xs text-slate-400">Scroll down in the share sheet</span>
              </div>
            </div>
            <img
              src="/add-to-home-screen.jpeg"
              alt="Add to Home Screen button"
              className="w-1/2 rounded-lg object-contain border border-slate-700 mt-2 mb-1 ml-12"
            />
          </li>
          <li className="flex items-start gap-4 py-3">
            <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-[1rem]">✅</div>
            <div className="flex flex-col gap-0.5 pt-0.5">
              <span className="text-sm font-semibold text-white">Tap "Add" to confirm</span>
              <span className="text-xs text-slate-400">The app will appear on your home screen</span>
            </div>
          </li>
        </ol>
      ) : (
        <div className="flex items-start gap-4 py-5">
          <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-slate-400">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 3v12M7 10l5 5 5-5"/><path d="M4 21h16"/>
            </svg>
          </div>
          <div className="flex flex-col gap-1 pt-0.5">
            <span className="text-sm font-semibold text-white">One tap to install</span>
            <span className="text-xs text-slate-400">
              {offlineReady
                ? 'Works offline · Fast · No app store needed'
                : 'Fast · No app store needed'}
            </span>
          </div>
        </div>
      )}

      <div className="h-px bg-slate-800" />

      <div className="flex flex-col gap-2 pt-4 pb-2">
        {!isIos && (
          <button
            type="button"
            onClick={onInstall}
            className="w-full min-h-11 py-3.5 rounded-lg bg-yellow-400 text-slate-950 font-bold text-sm active:scale-98 transition-transform"
          >
            Install App
          </button>
        )}
        <button
          type="button"
          onClick={onClose}
          className="w-full min-h-11 py-3 rounded-lg text-slate-400 font-medium text-sm active:scale-98 transition-transform"
        >
          {isIos ? 'Got it' : 'Not now'}
        </button>
      </div>
    </Overlay>
  )
}
