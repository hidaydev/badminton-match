import { useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useCommunityConfig } from '../community/useCommunityConfig'
import { t } from '../i18n'
import { getSessionStandings, listSessions } from '../sessions/api'
import type { SessionBoard, SessionMeta } from '../sessions/api'
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

type Source = 'tournament' | 'session'

type Composition =
  | { kind: 'group'; groupId: GroupId }
  | { kind: 'bracket'; phase: BracketPhase }
  | { kind: 'standings' }
  | { kind: 'final' }

type Scene =
  | { kind: 'tournament'; snapshot: Tournament; composition: Composition }
  | { kind: 'session'; board: SessionBoard }

type Choice = { key: string; label: string }

type Loaded<T> = { key: string; value: T | null; failed: boolean }

const LOGO_SRC = '/majadu-logo.png'

function unresolved<T>(): Loaded<T> {
  return { key: '', value: null, failed: false }
}

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

function drawScene(
  ctx: CanvasRenderingContext2D,
  scene: Scene,
  variant: Variant,
  dimensions: ExportDimensions,
  logo: HTMLImageElement | null,
): void {
  if (scene.kind === 'tournament') {
    drawComposition(ctx, scene.snapshot, scene.composition, variant, dimensions, logo)
    return
  }
  // The session board is the session variant of the standings composition.
  const rows = scene.board.items.map((item) => ({
    name: item.name,
    wins: item.wins,
    losses: item.losses,
    diff: item.diff,
    points: item.pointsFor,
  }))
  const input = {
    dimensions,
    meta: {
      date: scene.board.date,
      title: t('export.sessionBoard').toUpperCase(),
      playerCount: rows.length,
    },
    rows,
    hasPhoto: true,
    logoAspect: logo === null ? null : logo.naturalWidth / logo.naturalHeight,
  }
  const images = { photo: null, logo }
  if (variant === 'story') renderStandingsStory(ctx, input, images)
  else renderStandingsPost(ctx, input, images)
}

/** Staff export screen: post and story images for a session or a tournament. */
export default function ExportPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const communityConfig = useCommunityConfig(slug === '' ? null : slug)
  const [source, setSource] = useState<Source>('tournament')
  const [tournaments, setTournaments] = useState<Loaded<TournamentMeta[]>>(
    unresolved<TournamentMeta[]>(),
  )
  const [selectedTournament, setSelectedTournament] = useState('')
  const [snapshot, setSnapshot] = useState<Loaded<Tournament>>(unresolved<Tournament>())
  const [sessions, setSessions] = useState<Loaded<SessionMeta[]>>(
    unresolved<SessionMeta[]>(),
  )
  const [selectedSession, setSelectedSession] = useState('')
  const [board, setBoard] = useState<Loaded<SessionBoard>>(unresolved<SessionBoard>())
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
        if (active) setTournaments({ key, value: items, failed: false })
      })
      .catch(() => {
        if (active) setTournaments({ key, value: null, failed: true })
      })
    listSessions(slug)
      .then((items) => {
        if (active) setSessions({ key, value: items, failed: false })
      })
      .catch(() => {
        if (active) setSessions({ key, value: null, failed: true })
      })
    return () => {
      active = false
    }
  }, [slug])

  useEffect(() => {
    if (slug === '' || selectedTournament === '') return
    const key = `${slug}\u0000${selectedTournament}`
    let active = true
    getTournament(slug, selectedTournament)
      .then((value) => {
        if (!active) return
        setSnapshot({ key, value, failed: false })
        setChoice(choicesFor(value)[0]?.key ?? '')
      })
      .catch(() => {
        if (active) setSnapshot({ key, value: null, failed: true })
      })
    return () => {
      active = false
    }
  }, [slug, selectedTournament])

  useEffect(() => {
    if (slug === '' || selectedSession === '') return
    const key = `${slug}\u0000${selectedSession}`
    let active = true
    getSessionStandings(slug, selectedSession)
      .then((value) => {
        if (active) setBoard({ key, value, failed: false })
      })
      .catch(() => {
        if (active) setBoard({ key, value: null, failed: true })
      })
    return () => {
      active = false
    }
  }, [slug, selectedSession])

  useEffect(() => {
    let active = true
    loadImage(LOGO_SRC)
      .then((next) => {
        if (active) setLogo(next)
      })
      .catch(() => undefined)
    return () => {
      active = false
    }
  }, [])

  const listKey = slug
  const tournamentKey = `${slug}\u0000${selectedTournament}`
  const sessionKey = `${slug}\u0000${selectedSession}`

  const tournamentItems = tournaments.key === listKey ? tournaments.value : null
  const tournamentFailed = tournaments.key === listKey && tournaments.failed
  const snapshotValue = snapshot.key === tournamentKey ? snapshot.value : null
  const snapshotFailed = snapshot.key === tournamentKey && snapshot.failed
  const sessionItems = sessions.key === listKey ? sessions.value : null
  const sessionsFailed = sessions.key === listKey && sessions.failed
  const boardValue = board.key === sessionKey ? board.value : null
  const boardFailed = board.key === sessionKey && board.failed

  const composition = useMemo(() => parseChoice(choice), [choice])
  const choices = useMemo(
    () => (snapshotValue === null ? [] : choicesFor(snapshotValue)),
    [snapshotValue],
  )
  const scene = useMemo<Scene | null>(
    () =>
      source === 'session'
        ? boardValue === null
          ? null
          : { kind: 'session', board: boardValue }
        : snapshotValue === null || composition === null
          ? null
          : { kind: 'tournament', snapshot: snapshotValue, composition },
    [source, boardValue, snapshotValue, composition],
  )

  useEffect(() => {
    const canvas = canvasRef.current
    if (canvas === null || scene === null || dimensions === null) return
    const size = resolveCanvas(dimensions, variant)
    canvas.width = size.width
    canvas.height = size.height
    const ctx = canvas.getContext('2d')
    if (ctx === null) return
    try {
      drawScene(ctx, scene, variant, dimensions, logo)
      void Promise.resolve().then(() => setRenderFailed(false))
    } catch {
      void Promise.resolve().then(() => setRenderFailed(true))
    }
  }, [scene, variant, dimensions, logo])

  const download = () => {
    const canvas = canvasRef.current
    if (canvas === null) return
    const name =
      scene === null
        ? 'export'
        : scene.kind === 'session'
          ? scene.board.title
          : scene.snapshot.name
    const suffix = scene === null ? '' : scene.kind === 'session' ? 'standings' : choice.replace(':', '-')
    canvas.toBlob((blob) => {
      if (blob === null) return
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = `${name}-${suffix}-${variant}.png`
      anchor.click()
      URL.revokeObjectURL(url)
    }, 'image/png')
  }

  const tournamentLoading = selectedTournament !== '' && snapshot.key !== tournamentKey
  const sessionLoading = selectedSession !== '' && board.key !== sessionKey
  const listLoading = slug !== '' && tournaments.key !== listKey
  const canDownload = scene !== null && dimensions !== null && !renderFailed

  return (
    <section className="mx-auto max-w-5xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('export.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{t('export.subtitle')}</p>

      {(configFailed || communityConfig.error !== null) && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('export.error.config')}
        </p>
      )}

      <div className="mt-6 grid gap-4 lg:grid-cols-[minmax(0,1fr)_420px]">
        <div className="space-y-4">
          <fieldset>
            <legend className="text-sm font-semibold text-fg">{t('export.source')}</legend>
            <div className="mt-1 flex flex-wrap gap-x-6">
              {(['tournament', 'session'] as const).map((option) => (
                <label key={option} className="flex min-h-11 items-center gap-2 text-sm text-fg">
                  <input
                    type="radio"
                    name="export-source"
                    value={option}
                    checked={source === option}
                    onChange={() => {
                      setSource(option)
                      setRenderFailed(false)
                    }}
                    className="h-4 w-4 rounded border-border bg-elevated text-accent focus-visible:ring-2 focus-visible:ring-accent"
                  />
                  {t(
                    option === 'tournament'
                      ? 'export.source.tournament'
                      : 'export.source.session',
                  )}
                </label>
              ))}
            </div>
          </fieldset>

          {source === 'tournament' && (
            <>
              <div>
                <label htmlFor="export-tournament" className="block text-sm font-semibold text-fg">
                  {t('export.tournament')}
                </label>
                <select
                  id="export-tournament"
                  value={selectedTournament}
                  onChange={(event) => {
                    setSelectedTournament(event.target.value)
                    setChoice('')
                    setRenderFailed(false)
                  }}
                  className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
                >
                  <option value="">{t('export.chooseTournament')}</option>
                  {(tournamentItems ?? []).map((item) => (
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
              {tournamentFailed && (
                <p role="alert" className="text-sm text-error">
                  {t('export.error.list')}
                </p>
              )}
              {tournamentItems !== null && tournamentItems.length === 0 && (
                <p className="text-sm text-fg-dim">{t('export.empty')}</p>
              )}
              {tournamentLoading && (
                <p role="status" className="text-sm text-fg-dim">
                  {t('app.loading')}
                </p>
              )}
              {snapshotFailed && (
                <p role="alert" className="text-sm text-error">
                  {t('export.error.load')}
                </p>
              )}
            </>
          )}

          {source === 'session' && (
            <>
              <div>
                <label htmlFor="export-session" className="block text-sm font-semibold text-fg">
                  {t('export.session')}
                </label>
                <select
                  id="export-session"
                  value={selectedSession}
                  onChange={(event) => {
                    setSelectedSession(event.target.value)
                    setRenderFailed(false)
                  }}
                  className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
                >
                  <option value="">{t('export.chooseSession')}</option>
                  {(sessionItems ?? []).map((item) => (
                    <option key={item.id} value={item.id}>
                      {item.title} — {item.date}
                    </option>
                  ))}
                </select>
              </div>
              {sessionsFailed && (
                <p role="alert" className="text-sm text-error">
                  {t('export.error.sessions')}
                </p>
              )}
              {sessionItems !== null && sessionItems.length === 0 && (
                <p className="text-sm text-fg-dim">{t('export.empty')}</p>
              )}
              {sessionLoading && (
                <p role="status" className="text-sm text-fg-dim">
                  {t('app.loading')}
                </p>
              )}
              {boardFailed && (
                <p role="alert" className="text-sm text-error">
                  {t('export.error.board')}
                </p>
              )}
            </>
          )}

          {source === 'tournament' && snapshotValue !== null && (
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
          )}

          <fieldset>
            <legend className="text-sm font-semibold text-fg">{t('export.size')}</legend>
            <div className="mt-1 flex flex-wrap gap-x-6">
              {(['post', 'story'] as const).map((option) => (
                <label key={option} className="flex min-h-11 items-center gap-2 text-sm text-fg">
                  <input
                    type="radio"
                    name="export-size"
                    value={option}
                    checked={variant === option}
                    onChange={() => {
                      setVariant(option)
                      setRenderFailed(false)
                    }}
                    className="h-4 w-4 rounded border-border bg-elevated text-accent focus-visible:ring-2 focus-visible:ring-accent"
                  />
                  {t(option === 'post' ? 'export.size.post' : 'export.size.story')}
                </label>
              ))}
            </div>
          </fieldset>

          <button
            type="button"
            onClick={download}
            disabled={!canDownload}
            className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('export.download')}
          </button>

          {renderFailed && (
            <p role="alert" className="text-sm text-error">
              {t('export.error.render')}
            </p>
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
