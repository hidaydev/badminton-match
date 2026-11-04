import { useEffect, useState } from 'react'
import { CLIENT_OUTDATED_EVENT } from '../auth/api'
import { t } from '../i18n'

/**
 * A tab left open across a deploy keeps the bundle it loaded. When the server
 * answers `410 CLIENT_OUTDATED`, nothing on the page can work until the tab
 * fetches the new bundle, so the banner replaces guessing at a refresh.
 */
export default function ClientOutdatedBanner() {
  const [outdated, setOutdated] = useState(false)

  useEffect(() => {
    const onOutdated = () => setOutdated(true)
    window.addEventListener(CLIENT_OUTDATED_EVENT, onOutdated)
    return () => window.removeEventListener(CLIENT_OUTDATED_EVENT, onOutdated)
  }, [])

  if (!outdated) return null
  return (
    <div
      role="alert"
      className="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-elevated px-4 py-3"
    >
      <p className="text-sm text-fg">{t('app.outdated')}</p>
      <button
        type="button"
        onClick={() => window.location.reload()}
        className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent"
      >
        {t('app.outdated.action')}
      </button>
    </div>
  )
}
