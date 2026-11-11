import { useEffect, useState } from 'react'
import { CLIENT_OUTDATED_EVENT } from '../auth/api'
import { Button } from './Button'
import { ErrorText } from './ErrorText'

/**
 * A tab left open across a deploy keeps the bundle it loaded. When the server
 * answers `410 CLIENT_OUTDATED`, nothing on the page can work until the tab
 * fetches the new bundle, so the banner replaces guessing at a refresh.
 */
export function ClientOutdatedBanner({
  message = 'This tab is out of date.',
  actionLabel = 'Reload',
}: {
  /** Stated by the caller so the primitive owns no translation singleton. */
  message?: string
  actionLabel?: string
} = {}) {
  const [outdated, setOutdated] = useState(false)

  useEffect(() => {
    const onOutdated = () => setOutdated(true)
    window.addEventListener(CLIENT_OUTDATED_EVENT, onOutdated)
    return () => window.removeEventListener(CLIENT_OUTDATED_EVENT, onOutdated)
  }, [])

  if (!outdated) return null
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 bg-elevated border-b border-border px-4 py-3">
      <ErrorText inherit className="text-sm text-fg">{message}</ErrorText>
      <Button className="py-2" onClick={() => window.location.reload()}>
        {actionLabel}
      </Button>
    </div>
  )
}
