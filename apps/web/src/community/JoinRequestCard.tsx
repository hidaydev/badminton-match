import { useState } from 'react'
import { t } from '../i18n'
import { requestToJoin } from './api'

/**
 * The one action a signed-in account without a community can take. The API
 * answers the same 202 for every reason, so the form cannot tell the person
 * whether the slug exists — it only confirms the request left.
 */
export default function JoinRequestCard({
  slug,
  onSlugChange,
}: {
  slug: string
  onSlugChange: (value: string) => void
}) {
  const [sending, setSending] = useState(false)
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async () => {
    const value = slug.trim().toLowerCase()
    if (value === '') {
      setError(t('join.missing'))
      return
    }
    setSending(true)
    setError(null)
    try {
      await requestToJoin(value)
      setSent(true)
    } catch {
      setError(t('join.failed'))
    } finally {
      setSending(false)
    }
  }

  return (
    <section className="mt-6 rounded-2xl border border-border-subtle bg-surface p-4">
      <h2 className="text-sm font-semibold text-fg">{t('join.title')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('join.hint')}</p>
      <form
        className="mt-3 flex flex-wrap items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        <label htmlFor="join-slug" className="min-w-0 flex-1 text-xs text-fg-dim">
          {t('join.slug')}
          <input
            id="join-slug"
            type="text"
            autoComplete="off"
            autoCapitalize="none"
            spellCheck={false}
            value={slug}
            disabled={sending}
            onChange={(event) => {
              onSlugChange(event.target.value)
              setSent(false)
            }}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-60"
          />
        </label>
        <button
          type="submit"
          disabled={sending}
          className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {sending ? t('join.sending') : t('join.submit')}
        </button>
      </form>
      <p role="status" aria-live="polite" className="mt-2 text-xs text-fg-dim">
        {error ?? (sent ? t('join.sent') : '')}
      </p>
    </section>
  )
}