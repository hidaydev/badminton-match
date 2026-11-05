import { useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { TIERS } from '../players/api'
import { createPlayer } from '../players/api'
import { usePlayers } from '../players/hooks'
import { describePlayerError, parseAliases } from '../players/text'
import { LoadingState } from '../components/LoadingState'

export default function PlayersPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const role = memberships.find((candidate) => candidate.slug === slug)?.role ?? null
  const canManage = role === 'host' || role === 'admin'

  // The search lives in the URL so a filtered list can be linked to or
  // reloaded, and so the browser's back button undoes a search.
  const [searchParams, setSearchParams] = useSearchParams()
  const query = searchParams.get('q') ?? ''
  const [draft, setDraft] = useState(query)
  const { items, loading, loadingMore, error, hasMore, loadMore, reload } = usePlayers(
    slug === '' ? null : slug,
    query,
  )

  const [name, setName] = useState('')
  const [gender, setGender] = useState<'M' | 'F'>('M')
  const [tier, setTier] = useState('')
  const [aliases, setAliases] = useState('')
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)

  const add = async () => {
    if (slug === '' || name.trim() === '') return
    setBusy(true)
    setFormError(null)
    try {
      await createPlayer(slug, {
        name: name.trim(),
        gender,
        ...(tier === '' ? {} : { tier }),
        ...(parseAliases(aliases).length === 0 ? {} : { aliases: parseAliases(aliases) }),
      })
      setName('')
      setAliases('')
      reload()
    } catch (problem) {
      setFormError(describePlayerError(problem))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('players.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{t('players.subtitle')}</p>

      <form
        className="mt-4 flex items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          const next = draft.trim()
          setSearchParams(next === '' ? {} : { q: next }, { replace: true })
        }}
      >
        <label className="min-w-0 flex-1 text-xs text-fg-dim">
          {t('players.search')}
          <input
            type="search"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder={t('players.search.placeholder')}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
        <button
          type="submit"
          className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('players.search.action')}
        </button>
      </form>

      {loading && <LoadingState label={t('app.loading')} rows={1} />}
      {error !== null && (
        <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
          {t('players.error.load')}
        </p>
      )}
      {items !== null && items.length === 0 && (
        <p className="mt-4 text-sm text-fg-dim">{t('players.empty')}</p>
      )}

      {items !== null && items.length > 0 && (
        <ul className="mt-4 space-y-2">
          {items.map((player) => (
            <li key={player.id}>
              <Link
                to={`/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(player.id)}`}
                className="flex min-h-11 items-center justify-between gap-3 rounded-xl border border-border-subtle bg-surface px-4 py-3 hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
              >
                <span className="min-w-0">
                  <span className="block truncate text-sm font-semibold text-fg">
                    {player.name}
                  </span>
                  <span className="mt-0.5 block text-xs text-fg-dim">
                    {player.tier ?? t('players.tier.none')}
                  </span>
                </span>
                <span className="shrink-0 text-xs text-fg-dim">
                  {player.userId === null
                    ? t('players.unclaimed')
                    : t('players.claimed')}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}

      {hasMore && (
        <button
          type="button"
          disabled={loadingMore}
          onClick={loadMore}
          className="mt-3 min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {loadingMore ? t('players.loadingMore') : t('players.loadMore')}
        </button>
      )}

      {canManage && (
        <form
          className="mt-8 rounded-2xl border border-border-subtle bg-surface p-4"
          onSubmit={(event) => {
            event.preventDefault()
            void add()
          }}
        >
          <h2 className="text-sm font-semibold text-fg">{t('players.add')}</h2>
          {formError !== null && (
            <p role="alert" className="mt-2 text-sm text-error">
              {formError}
            </p>
          )}
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <label className="text-xs text-fg-dim">
              {t('players.add.name')}
              <input
                value={name}
                onChange={(event) => setName(event.target.value)}
                required
                maxLength={80}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </label>
            <label className="text-xs text-fg-dim">
              {t('players.add.gender')}
              <select
                value={gender}
                onChange={(event) => setGender(event.target.value === 'F' ? 'F' : 'M')}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              >
                <option value="M">{t('player.gender.male')}</option>
                <option value="F">{t('player.gender.female')}</option>
              </select>
            </label>
            <label className="text-xs text-fg-dim">
              {t('players.add.tier')}
              <select
                value={tier}
                onChange={(event) => setTier(event.target.value)}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              >
                <option value="">{t('players.tier.none')}</option>
                {TIERS.map((value) => (
                  <option key={value} value={value}>
                    {value}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-xs text-fg-dim">
              {t('players.add.aliases')}
              <input
                value={aliases}
                onChange={(event) => setAliases(event.target.value)}
                aria-describedby="players-aliases-hint"
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </label>
          </div>
          <p id="players-aliases-hint" className="mt-2 text-xs text-fg-dim">
            {t('players.add.aliasesHint')}
          </p>
          <button
            type="submit"
            disabled={busy || name.trim() === ''}
            className="mt-3 min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('players.add.submit')}
          </button>
        </form>
      )}
    </section>
  )
}
