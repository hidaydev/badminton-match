import { Link, Outlet, useLocation, useNavigate, useParams } from 'react-router-dom'
import { t } from '../i18n'
import { useWizard } from '../wizard/context'
import { WizardProvider } from '../wizard/store'

const STEPS = [
  { segment: 'new', labelKey: 'wizard.step.setup' },
  { segment: 'players', labelKey: 'wizard.step.players' },
  { segment: 'constraints', labelKey: 'wizard.step.constraints' },
  { segment: 'generate', labelKey: 'wizard.step.generate' },
] as const

function Progress() {
  const { slug = '' } = useParams<{ slug: string }>()
  const location = useLocation()
  const navigate = useNavigate()
  const { draft, resetDraft } = useWizard()
  const base = `/c/${encodeURIComponent(slug)}/session`

  const currentIndex = Math.max(
    0,
    STEPS.findLastIndex((step) => location.pathname.startsWith(`${base}/${step.segment}`)),
  )
  const hasSchedule = draft.schedule.length > 0
  const isComplete = draft.players.length === draft.session.playerCount
  const maxReached = Math.max(
    hasSchedule ? 3 : draft.session.locked && isComplete ? 2 : draft.session.locked ? 1 : 0,
    currentIndex,
  )

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
        <div className="max-w-3xl mx-auto px-3 py-2.5 flex items-center gap-2">
          <button
            type="button"
            onClick={() => navigate(-1)}
            className="p-1.5 -ml-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all shrink-0"
            aria-label={t('shell.back')}
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M15 18l-6-6 6-6" />
            </svg>
          </button>
          <Link to={`/c/${encodeURIComponent(slug)}`} className="flex items-center gap-2">
            <img src="/logo-192.png" alt={t('app.name')} className="w-6 h-6 shrink-0 object-contain" />
            <h1 className="text-sm font-bold text-fg tracking-tight whitespace-nowrap">{t('app.name').toUpperCase()}</h1>
          </Link>
          {draft.session.locked && (
            <div className="ml-auto flex items-center gap-2 shrink-0">
              <span className="flex items-center gap-1.5 text-xs text-fg-dim">
                <span className="w-1.5 h-1.5 rounded-full bg-success shrink-0" />
                {t('shell.active')}
              </span>
              <button
                type="button"
                onClick={() => {
                  if (!window.confirm(t('shell.resetConfirm'))) return
                  resetDraft()
                  navigate(`${base}/new`)
                }}
                className="text-xs text-fg-dim hover:text-error transition-colors px-2 py-1 rounded-md border border-border-subtle"
              >
                {t('shell.reset')}
              </button>
            </div>
          )}
        </div>

        <div className="max-w-3xl mx-auto px-3 pb-2">
          <div className="flex items-center gap-2">
            <div className="flex gap-1 flex-1">
              {STEPS.map((step, index) => {
                const done = index < maxReached
                const active = index === currentIndex
                return (
                  <div
                    key={step.segment}
                    aria-hidden
                    className={`h-1 flex-1 rounded-full transition-colors ${
                      active || done ? 'bg-accent' : 'bg-slate-700'
                    }`}
                  />
                )
              })}
            </div>
            <span className="text-[10px] font-sans text-fg-dim uppercase shrink-0 tracking-[0.08em]">
              {currentIndex + 1} · {t(STEPS[currentIndex].labelKey)}
            </span>
          </div>
        </div>
      </header>

      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4 pb-[env(safe-area-inset-bottom)]">
        <Outlet />
      </main>
    </div>
  )
}

export default function SessionLayout() {
  const { slug = '' } = useParams<{ slug: string }>()
  return (
    <WizardProvider key={slug} slug={slug}>
      <Progress />
    </WizardProvider>
  )
}
