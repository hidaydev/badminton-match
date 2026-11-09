import { Overlay } from '../../components/Overlay'
import { t } from '../../i18n'

interface InstallModalProps {
  isIos: boolean
  onInstall(): void
  onClose(): void
}

// The sheet body owns the horizontal padding and the safe area; `labelledBy`
// points at the identity heading so the logo stays above the title.
export default function InstallModal({ isIos, onInstall, onClose }: InstallModalProps) {
  return (
    <Overlay onClose={onClose} title={t('home.installApp')} labelledBy="install-sheet-title">
      {/* App identity */}
      <div className="flex flex-col items-center gap-2 pt-4 pb-5">
        <img src="/logo-192.png" alt="" className="w-16 h-16 rounded-lg object-contain" />
        <div className="text-center">
          <h2 id="install-sheet-title" className="text-white font-bold text-lg leading-tight">Install MAJADU App</h2>
          <p className="text-slate-400 text-sm mt-0.5">
            {isIos ? 'Add to your home screen in a few steps' : 'Get quick access right from your home screen'}
          </p>
        </div>
      </div>

      {/* Divider */}
      <div className="h-px bg-slate-800" />

      {/* iOS steps */}
      {isIos ? (
        <ol className="flex flex-col gap-0 py-4">
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
              alt={t('install.addToHomeScreen')}
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
          <div className="shrink-0 w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-fg-dim"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"><path d="M12 3v12M7 10l5 5 5-5"/><path d="M4 21h16"/></svg></div>
          <div className="flex flex-col gap-1 pt-0.5">
            <span className="text-sm font-semibold text-white">One tap to install</span>
            <span className="text-xs text-slate-400">Opens from your home screen · No app store needed</span>
          </div>
        </div>
      )}

      {/* Divider */}
      <div className="h-px bg-slate-800" />

      {/* Actions */}
      <div className="flex flex-col gap-2 pt-4 pb-2">
        {!isIos && (
          <button
            onClick={onInstall}
            className="w-full py-3.5 rounded-lg bg-yellow-400 text-slate-950 font-bold text-sm
              active:scale-98 transition-transform hit44"
          >
            {t('legacy.installApp')}
          </button>
        )}
        <button
          onClick={onClose}
          className="w-full py-3 rounded-lg text-slate-400 font-medium text-sm
            active:scale-98 transition-transform hit44"
        >
          {isIos ? 'Got it' : 'Not now'}
        </button>
      </div>
    </Overlay>
  )
}