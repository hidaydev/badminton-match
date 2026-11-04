import { useState } from 'react'
import type { FormEvent } from 'react'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n'
import { saveErrorKey } from './errors'

type Props = {
  initialName: string
  initialDate: string
  onSave: (name: string, date: string) => Promise<void>
}

/** Name and date of an existing tournament; saved with a full replace. */
export function MetadataForm({ initialName, initialDate, onSave }: Props) {
  const [name, setName] = useState(initialName)
  const [date, setDate] = useState(initialDate)
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)
  const [error, setError] = useState<MessageKey | null>(null)

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setSaving(true)
    setSaved(false)
    setError(null)
    try {
      await onSave(name.trim(), date)
      setSaved(true)
    } catch (failure: unknown) {
      setError(saveErrorKey(failure))
    } finally {
      setSaving(false)
    }
  }

  return (
    <form onSubmit={(event) => void submit(event)} className="mt-4 grid gap-3 sm:grid-cols-2">
      <div className="grid gap-1">
        <label htmlFor="tournament-name" className="text-xs text-fg-dim">
          {t('tournament.name')}
        </label>
        <input
          id="tournament-name"
          value={name}
          onChange={(event) => {
            setName(event.target.value)
            setSaved(false)
          }}
          className="min-h-11 rounded-xl border border-border bg-elevated px-3 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
        />
      </div>
      <div className="grid gap-1">
        <label htmlFor="tournament-date" className="text-xs text-fg-dim">
          {t('tournament.date')}
        </label>
        <input
          id="tournament-date"
          type="date"
          value={date}
          onChange={(event) => {
            setDate(event.target.value)
            setSaved(false)
          }}
          className="min-h-11 rounded-xl border border-border bg-elevated px-3 py-1.5 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
        />
      </div>

      <div className="flex flex-wrap items-center gap-3 sm:col-span-2">
        <button
          type="submit"
          disabled={saving}
          className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
        >
          {saving ? t('tournament.saving') : t('tournament.save')}
        </button>
        {saved && (
          <p role="status" className="text-xs text-fg-dim">
            {t('tournament.saved')}
          </p>
        )}
      </div>
      {error !== null && (
        <p role="alert" className="text-sm text-error sm:col-span-2">
          {t(error)}
        </p>
      )}
    </form>
  )
}
