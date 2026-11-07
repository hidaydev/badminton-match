import { useEffect, useState } from 'react'
import { t } from '../i18n'
import { listDirectory } from './api'
import type { DirectoryEntry } from './api'

/**
 * The communities that opted into the directory. Picking one only fills the
 * join form: the request still needs the explicit send, so a stray tap cannot
 * queue a request an admin then has to refuse.
 */
export default function DirectoryList({ onPick }: { onPick: (slug: string) => void }) {
  const [items, setItems] = useState<DirectoryEntry[]>([])

  useEffect(() => {
    let active = true
    listDirectory()
      .then((rows) => {
        if (active) setItems(rows)
      })
      .catch(() => {
        // The directory is a convenience; the slug field below still works.
        if (active) setItems([])
      })
    return () => {
      active = false
    }
  }, [])

  if (items.length === 0) return null

  return (
    <section className="mt-6 rounded-2xl border border-border-subtle bg-surface p-4">
      <h2 className="text-sm font-semibold text-fg">{t('directory.title')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('directory.hint')}</p>
      <ul className="mt-3 flex flex-col gap-2">
        {items.map((entry) => (
          <li key={entry.slug}>
            <button
              type="button"
              onClick={() => onPick(entry.slug)}
              className="flex min-h-11 w-full items-center justify-between gap-3 rounded-xl border border-border bg-elevated px-3 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent"
            >
              <span className="truncate font-semibold">{entry.name}</span>
              <span className="shrink-0 text-xs text-fg-dim">{entry.slug}</span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}