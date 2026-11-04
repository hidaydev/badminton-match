import { useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useCommunityConfig } from '../community/useCommunityConfig'
import { t } from '../i18n'
import { getTournament, listTournaments } from '../tournament/api'
import {
  classicBracketRows,
  classicGroupRows,
  teamFinalExport,
  teamStandingRows,
} from '../tournament/export'
import type { BracketPhase } from '../tournament/export'
import { isTeam } from '../tournament/types'
import type {
  ClassicSnapshot,
  GroupId,
  TeamSnapshot,
  Tournament,
  TournamentMeta,
} from '../tournament/types'
import {
  exportDimensions,
  loadImage,
  renderBracketCoverPost,
  renderBracketCoverStory,
  renderGroupSummaryPost,
  renderGroupSummaryStory,
  renderStandingsPost,
  renderStandingsStory,
  renderTeamMatchPost,
  renderTeamMatchStory,
  resolveCanvas,
} from '../utils/canvas'
import type { ExportDimensions, Variant } from '../utils/canvas'

type Composition =
  | { kind: 'group'; groupId: GroupId }
  | { kind: 'bracket'; phase: BracketPhase }
  | { kind: 'standings' }
  | { kind: 'final' }

type Choice = { key: string; label: string }

type ListState = {
  key: string
  items: TournamentMeta[] | null
  failed: boolean
}

type SnapshotState = {
  key: string
  snapshot: Tournament | null
  failed: boolean
}

const LOGO_SRC = '/majadu-logo.png'

function parseChoice(key: string): Composition | null {
  if (key.startsWith('group:')) {
    return { kind: 'group', groupId: key.slice(6) as GroupId }
  }
  if (key.startsWith('bracket:')) {
    return { kind: 'bracket', phase: key.slice(8) as BracketPhase }
  }
  if (key === 'standings') return { kind: 'standings' }
  if (key === 'final') return { kind: 'final' }
  return null
}

function choicesFor(snapshot: Tournament): Choice[] {
  if (isTeam(snapshot)) {
    return [
      { key: 'standings', label: t('export.standings') },
      ...(snapshot.matches.some((match) => match.phase === 'final')
        ? [{ key: 'final', label: t('export.final') }]
        : []),
    ]
  }
  const groups: Choice[] = (['A', 'B', 'C', 'D'] as const).map((groupId) => ({
    key: `group:${groupId}`,
    label: t('export.group', { group: groupId }),
  }))
  return [
    ...groups,
    { key: 'bracket:qf', label: t('export.bracket.qf') },
    { key: 'bracket:sf', label: t('export.bracket.sf') },
    { key: 'bracket:3rd', label: t('export.bracket.third') },
    { key: 'bracket:final', label: t('export.bracket.final') },
  ]
}

function drawComposition(
  ctx: CanvasRenderingContext2D,
  snapshot: Tournament,
  composition: Composition,
  variant: Variant,
  dimensions: ExportDimensions,
  logo: HTMLImageElement | null,
): void {
  const logoAspect = logo === null ? null : logo.naturalWidth / logo.naturalHeight
  const story = variant === 'story'
  if (composition.kind === 'group' && !isTeam(snapshot)) {
    const input = {
      dimensions,
      groupId: composition.groupId,
      rows: classicGroupRows(snapshot as ClassicSnapshot, composition.groupId),
      aspects: { logo: logoAspect },
    }
    const images = { background: null, logo, sponsor: null }
    if (story) renderGroupSummaryStory(ctx, input, images)
    else renderGroupSummaryPost(ctx, input, images)
    return
  }
  if (composition.kind === 'bracket' && !isTeam(snapshot)) {
    const input = {
      dimensions,
      roundTitle: t(
        composition.phase === 'qf'
          ? 'export.bracket.qf'
          : composition.phase === 'sf'
            ? 'export.bracket.sf'
            : composition.phase === '3rd'
              ? 'export.bracket.third'
              : 'export.bracket.final',
      ).toUpperCase(),
      rows: classicBracketRows(snapshot as ClassicSnapshot, composition.phase),
      aspects: { logo: logoAspect, sponsor: null },
    }
    const images = { background: null, logo, sponsor: null }
    if (story) renderBracketCoverStory(ctx, input, images)
    else renderBracketCoverPost(ctx, input, images)
    return
  }
  if (composition.kind === 'standings' && isTeam(snapshot)) {
    const rows = teamStandingRows(snapshot as TeamSnapshot)
    const input = {
      dimensions,
      meta: {
        date: snapshot.date,
        title: t('export.standings').toUpperCase(),
        playerCount: rows.length,
      },
      rows,
      // The card is the intended surface; v1 only skipped it when no photo was
      // supplied, which would leave the rows on a bare dark fill.
      hasPhoto: true,
      logoAspect,
    }
    const images = { photo: null, logo }
    if (story) renderStandingsStory(ctx, input, images)
    else renderStandingsPost(ctx, input, images)
    return
  }
  if (composition.kind === 'final' && isTeam(snapshot)) {
    const final = teamFinalExport(snapshot as TeamSnapshot)
    if (final === null) return
    const input = {
      dimensions,
      teamAName: final.teamAName,
      teamBName: final.teamBName,
      teamAWins: final.teamAWins,
      teamBWins: final.teamBWins,
      partai: final.partai,
      subtitle: snapshot.name,
      aspects: { logo: logoAspect },
    }
    const images = { logo }
    if (story) renderTeamMatchStory(ctx, input, images)
    else renderTeamMatchPost(ctx, input, images)
  }
}

/** Staff export screen: post and story images for a stored tournament. */
export default function ExportPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const communityConfig = useCommunityConfig(slug === '' ? null : slug)
  const [list, setList] = useState<ListState>({ key: '', items: null, failed: false })
  const [selectedId, setSelectedId] = useState('')
  const [loaded, setLoaded] = useState<SnapshotState>({
    key: '',
    snapshot: null,
    failed: false,
  })
  const [choice, setChoice] = useState('')
  const [variant, setVariant] = useState<Variant>('post')
  const [logo, setLogo] = useState<HTMLImageElement | null>(null)
  const [renderFailed, setRenderFailed] = useState(false)
  const canvasRef = useRef<HTMLCanvasElement | null>(null)

  let dimensions: ExportDimensions | null = null
  let configFailed = false
  if (communityConfig.config !== null) {
    try {
      dimensions = exportDimensions(communityConfig.config)
    } catch {
      configFailed = true
    }
  }

  useEffect(() => {
    if (slug === '') return
    const key = slug
    let active = true
    listTournaments(slug)
      .then((items) => {
        if (active) setList({ key, items, failed: false })
      })
      .catch(() => {
        if (active) setList({ key, items: null, failed: true })
      })
    return () => {
      active = false
    }
  }, [slug])

  useEffect(() => {
    if (slug === '' || selectedId === '') return
    const key = `${slug}\u0000${selectedId}`
    let active = true
    getTournament(slug, selectedId)
      .then((snapshot) => {
        if (!active) return
        setLoaded({ key, snapshot, failed: false })
        setChoice(choicesFor(snapshot)[0]?.key ?? '')
      })
      .catch(() => {
        if (active) setLoaded({ key, snapshot: null, failed: true })
      })
    return () => {
      active = false
    }
  }, [slug, selectedId])

  useEffect(() => {
    let active = true
    loadImage(LOGO_SRC)
      .then((nextLogo) => {
        if (active) setLogo(nextLogo)
      })
      .catch(() => undefined)
    return () => {
      active = false
    }
  }, [])

  const listKey = slug
  const snapshotKey = `${slug}\u0000${selectedId}`
  const items = list.key === listKey ? list.items : null
  const listFailed = list.key === listKey && list.failed
  const snapshot = loaded.key === snapshotKey ? loaded.snapshot : null
  const snapshotFailed = loaded.key === snapshotKey && loaded.failed
  const composition = parseChoice(choice)
  const choices = snapshot === null ? [] : choicesFor(snapshot)

  useEffect(() => {
    const canvas = canvasRef.current
    if (canvas === null || snapshot === null || dimensions === null || composition === null) {
      return
    }
    const size = resolveCanvas(dimensions, variant)
    canvas.width = size.width
    canvas.height = size.height
    const ctx = canvas.getContext('2d')
    if (ctx === null) return
    try {
      drawComposition(ctx, snapshot, composition, variant, dimensions, logo)
      void Promise.resolve().then(() => setRenderFailed(false))
    } catch {
      void Promise.resolve().then(() => setRenderFailed(true))
    }
  }, [snapshot, dimensions, composition, variant, logo])

  const download = () => {
    const canvas = canvasRef.current
    if (canvas === null) return
    canvas.toBlob((blob) => {
      if (blob === null) return
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = `${snapshot?.name ?? 'tournament'}-${choice.replace(':', '-')}-${variant}.png`
      anchor.click()
      URL.revokeObjectURL(url)
    }, 'image/png')
  }

  const listLoading = slug !== '' && list.key !== listKey
  const snapshotLoading = selectedId !== '' && loaded.key !== snapshotKey

  return (
    <section className="mx-auto max-w-5xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('export.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{t('export.subtitle')}</p>

      {configFailed && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('export.error.config')}
        </p>
      )}
      {communityConfig.error !== null && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('export.error.config')}
        </p>
      )}

      <div className="mt-6 grid gap-4 lg:grid-cols-[minmax(0,1fr)_420px]">
        <div className="space-y-4">
          <div>
            <label htmlFor="export-tournament" className="block text-sm font-semibold text-fg">
              {t('export.tournament')}
            </label>
            <select
              id="export-tournament"
              value={selectedId}
              onChange={(event) => {
                setSelectedId(event.target.value)
                setChoice('')
                setRenderFailed(false)
              }}
              className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
            >
              <option value="">{t('export.chooseTournament')}</option>
              {(items ?? []).map((item) => (
                <option key={item.id} value={item.id}>
                  {item.name} — {item.date}
                </option>
              ))}
            </select>
          </div>

          {listLoading && (
            <p role="status" className="text-sm text-fg-dim">
              {t('app.loading')}
            </p>
          )}
          {listFailed && (
            <p role="alert" className="text-sm text-error">
              {t('export.error.list')}
            </p>
          )}
          {items !== null && items.length === 0 && (
            <p className="text-sm text-fg-dim">{t('export.empty')}</p>
          )}
          {snapshotLoading && (
            <p role="status" className="text-sm text-fg-dim">
              {t('app.loading')}
            </p>
          )}
          {snapshotFailed && (
            <p role="alert" className="text-sm text-error">
              {t('export.error.load')}
            </p>
          )}

          {snapshot !== null && (
            <>
              <div>
                <label htmlFor="export-image" className="block text-sm font-semibold text-fg">
                  {t('export.image')}
                </label>
                <select
                  id="export-image"
                  value={choice}
                  onChange={(event) => {
                    setChoice(event.target.value)
                    setRenderFailed(false)
                  }}
                  className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
                >
                  {choices.map((option) => (
                    <option key={option.key} value={option.key}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </div>

              <fieldset>
                <legend className="text-sm font-semibold text-fg">{t('export.size')}</legend>
                <div className="mt-1 flex gap-2">
                  {(['post', 'story'] as const).map((option) => (
                    <label
                      key={option}
                      className={`min-h-11 flex-1 cursor-pointer rounded-xl border px-3 py-2 text-center text-sm focus-within:ring-2 focus-within:ring-accent ${
                        variant === option
                          ? 'border-accent bg-accent text-ground font-semibold'
                          : 'border-border text-fg'
                      }`}
                    >
                      <input
                        type="radio"
                        name="export-size"
                        value={option}
                        checked={variant === option}
                        onChange={() => {
                          setVariant(option)
                          setRenderFailed(false)
                        }}
                        className="sr-only"
                      />
                      {t(option === 'post' ? 'export.size.post' : 'export.size.story')}
                    </label>
                  ))}
                </div>
              </fieldset>

              <button
                type="button"
                onClick={download}
                disabled={dimensions === null || renderFailed}
                className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
              >
                {t('export.download')}
              </button>

              {renderFailed && (
                <p role="alert" className="text-sm text-error">
                  {t('export.error.render')}
                </p>
              )}
            </>
          )}
        </div>

        <div>
          <canvas
            ref={canvasRef}
            aria-label={t('export.title')}
            className="w-full rounded-2xl border border-border bg-ground"
          />
        </div>
      </div>
    </section>
  )
}
