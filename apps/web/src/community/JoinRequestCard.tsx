import { useState } from 'react'
import { t } from '../i18n'
import { Button } from '../components/Button'
import { Card } from '../components/Card'
import { Field, Input } from '../components/Field'
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
    <Card className="mt-6 p-4">
      <h2 className="text-sm font-semibold text-fg">{t('join.title')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('join.hint')}</p>
      <form
        className="mt-3 flex flex-wrap items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        <Field label={t('join.slug')} className="min-w-0 flex-1">
          <Input
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
            className="disabled:opacity-60"
          />
        </Field>
        <Button type="submit" disabled={sending}>
          {sending ? t('join.sending') : t('join.submit')}
        </Button>
      </form>
      <p role="status" aria-live="polite" className="mt-2 text-xs text-fg-dim">
        {error ?? (sent ? t('join.sent') : '')}
      </p>
    </Card>
  )
}