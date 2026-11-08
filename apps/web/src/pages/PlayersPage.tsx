import { useEffect, useRef, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { TIERS } from '../players/api'
import { createPlayer } from '../players/api'
import { usePlayers } from '../players/hooks'
import { describePlayerError, parseAliases } from '../players/text'
import { Button } from '../components/Button'
import { ErrorText } from '../components/ErrorText'
import { Field, Input, Select } from '../components/Field'
import { LoadingState } from '../components/LoadingState'
import { PageHeader } from '../components/PageHeader'

/** A search fires after this pause, so typing a name is one request. */
const SEARCH_DEBOUNCE_MS = 300

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
  const [draftOf, setDraftOf] = useState(query)

  // The empty state offers "Add player" and points at this panel. A `details`
  // element is not opened by an anchor, so the link opens it itself; the panel
  // stays uncontrolled so the summary keeps toggling with no state to sync.
  const addPanel = useRef<HTMLDetailsElement>(null)

  // The URL is the source of truth: when it changes from the outside (back
  // button, a Find press), the box follows. Adjusting state during render is
  // the documented way to reset from a prop without an effect.
  if (draftOf !== query) {
    setDraftOf(query)
    setDraft(query)
  }

  // Typing searches on its own, after a pause long enough that a fast typist
  // does not issue a request per keystroke. The Find button stays for a search
  // the moment it is typed.
  useEffect(() => {
    const next = draft.trim()
    if (next === query) return
    const timer = window.setTimeout(() => {
      setSearchParams(next === '' ? {} : { q: next }, { replace: true })
    }, SEARCH_DEBOUNCE_MS)
    return () => window.clearTimeout(timer)
  }, [draft, query, setSearchParams])

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
      <PageHeader title={t('players.title')} subtitle={t('players.subtitle')} />

      <form
        className="mt-4 flex items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault()
          const next = draft.trim()
          setSearchParams(next === '' ? {} : { q: next }, { replace: true })
        }}
      >
        <Field label={t('players.search')} className="min-w-0 flex-1">
          <Input
            type="search"
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder={t('players.search.placeholder')}
          />
        </Field>
        <Button type="submit" variant="secondary">
          {t('players.search.action')}
        </Button>
      </form>

      {loading && <LoadingState label={t('app.loading')} rows={1} />}
      {error !== null && (
        <ErrorText className="mt-4">{t('players.error.load')}</ErrorText>
      )}
      {items !== null && items.length === 0 && (
        <div className="mt-4 rounded-xl border border-border-subtle bg-surface p-4 text-center">
          <p className="text-sm text-fg-dim">{t('players.empty')}</p>
          {(query !== '' || canManage) && (
            <p className="mt-1 text-xs text-fg-dim">
              {query === ''
                ? t('players.empty.hint')
                : t('players.empty.hintQuery', { query })}
            </p>
          )}
          {query !== '' ? (
            <Button
              variant="secondary"
              className="mt-3"
              onClick={() => {
                setDraft('')
                setSearchParams({}, { replace: true })
              }}
            >
              {t('players.empty.clear')}
            </Button>
          ) : (
            canManage && (
              <a
                href="#players-add"
                onClick={() => {
                  if (addPanel.current !== null) addPanel.current.open = true
                }}
                className="mt-3 inline-flex min-h-11 items-center rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent"
              >
                {t('players.add')}
              </a>
            )
          )}
        </div>
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
        <Button
          variant="secondary"
          className="mt-3"
          disabled={loadingMore}
          onClick={loadMore}
        >
          {loadingMore ? t('players.loadingMore') : t('players.loadMore')}
        </Button>
      )}

      {canManage && (
        <details
          ref={addPanel}
          id="players-add"
          className="mt-8 scroll-mt-20 rounded-2xl border border-border-subtle bg-surface p-4"
        >
          <summary className="min-h-11 cursor-pointer text-sm font-semibold text-fg">
            {t('players.add')}
          </summary>
          <form
            onSubmit={(event) => {
              event.preventDefault()
              void add()
            }}
          >
            {formError !== null && (
              <ErrorText className="mt-2">{formError}</ErrorText>
            )}
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <Field label={t('players.add.name')}>
                <Input
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                  required
                  maxLength={80}
                />
              </Field>
              <Field label={t('players.add.gender')}>
                <Select
                  value={gender}
                  onChange={(event) => setGender(event.target.value === 'F' ? 'F' : 'M')}
                >
                  <option value="M">{t('player.gender.male')}</option>
                  <option value="F">{t('player.gender.female')}</option>
                </Select>
              </Field>
              <Field label={t('players.add.tier')}>
                <Select value={tier} onChange={(event) => setTier(event.target.value)}>
                  <option value="">{t('players.tier.none')}</option>
                  {TIERS.map((value) => (
                    <option key={value} value={value}>
                      {value}
                    </option>
                  ))}
                </Select>
              </Field>
              <Field label={t('players.add.aliases')}>
                <Input
                  value={aliases}
                  onChange={(event) => setAliases(event.target.value)}
                  aria-describedby="players-aliases-hint"
                />
              </Field>
            </div>
            <p id="players-aliases-hint" className="mt-2 text-xs text-fg-dim">
              {t('players.add.aliasesHint')}
            </p>
            <Button
              type="submit"
              className="mt-3"
              disabled={busy || name.trim() === ''}
            >
              {t('players.add.submit')}
            </Button>
          </form>
        </details>
      )}
    </section>
  )
}
