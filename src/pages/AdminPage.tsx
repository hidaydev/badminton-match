// src/pages/AdminPage.tsx — halaman admin (ADMIN_MENU_PLAN §2.2).
import { useMemo, useRef, useState, useEffect } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { useAdmin } from '../context/AdminContext'
import { useListSessions, useListPlayers, useListTournaments } from '../queries'
import { useRatingSources, useRatingSeasons } from '../queries/ratings'
import { adminRequest } from '../queries/admin'
import { t, en } from '../i18n'

// 8-tier (TIER_8_UNIFICATION): D, D+, C, C+, B, B+, A, A+
const TIERS = ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+']
const PAGE = 10

// Tombol aksi kecil — gaya seragam.
function ActionButton({ onClick, children, tone = 'neutral', disabled }: {
  onClick: () => void
  children: React.ReactNode
  tone?: 'neutral' | 'amber' | 'red' | 'green'
  disabled?: boolean
}) {
  const tones = {
    neutral: 'border-border text-fg-dim hover:text-fg',
    amber: 'border-amber-700/50 text-amber-300 hover:bg-amber-900/40',
    red: 'border-red-800/50 text-red-400 hover:bg-red-950/40',
    green: 'border-emerald-700/60 text-emerald-400 hover:bg-emerald-950/40',
  }
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`text-[10px] font-mono px-2 py-1 rounded border transition-colors disabled:opacity-40 ${tones[tone]}`}
    >
      {children}
    </button>
  )
}

function Pager({ page, total, onPage }: { page: number; total: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / PAGE))
  if (pages <= 1) return null
  return (
    <div className="flex items-center justify-between px-1">
      <button
        onClick={() => onPage(page - 1)}
        disabled={page <= 0}
        className="text-xs font-mono text-fg-dim hover:text-fg disabled:opacity-30"
      >
        {t('common.prev')}
      </button>
      <span className="text-[10px] font-mono text-fg-dim">{page + 1} / {pages}</span>
      <button
        onClick={() => onPage(page + 1)}
        disabled={page >= pages - 1}
        className="text-xs font-mono text-fg-dim hover:text-fg disabled:opacity-30"
      >
        {t('common.next')}
      </button>
    </div>
  )
}

export default function AdminPage() {
  const { isAdmin, logout } = useAdmin()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const [error, setError] = useState<string | null>(null)
  const [okMsg, setOkMsg] = useState<string | null>(null)

  // Pagination: sessions, sources & players (10/item)
  const [sessPage, setSessPage] = useState(0)
  const [srcPage, setSrcPage] = useState(0)
  const [playerPage, setPlayerPage] = useState(0)
  const [playerQuery, setPlayerQuery] = useState('')
  // "now" stabil (sekali per mount) — daySpan jadi murni (lint: no impure in render)
  const [nowMs] = useState(() => Date.now())

  // Add player standalone (nama + tier induk — tanpa chain ke sesi)
  const [newName, setNewName] = useState('')
  const [newTier, setNewTier] = useState('C')

  // Autofocus section dari /admin?section=X (dari card menu home) — tanpa collapsible.
  const sectionRefs = useRef<Record<string, HTMLElement | null>>({})
  const sessionsRef = useRef<HTMLElement>(null)
  const playersRef = useRef<HTMLElement>(null)
  const ratingsRef = useRef<HTMLElement>(null)
  const tournamentRef = useRef<HTMLElement>(null)
  const seasonRef = useRef<HTMLElement>(null)
  useEffect(() => {
    sectionRefs.current = { sessions: sessionsRef.current, players: playersRef.current, ratings: ratingsRef.current, tournament: tournamentRef.current, season: seasonRef.current }
    const sec = searchParams.get('section')
    if (sec && sectionRefs.current[sec]) {
      sectionRefs.current[sec]?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams])

  // Feedback Rebuild All — inline dekat tombol (bukan flash global di atas)
  const [rebuildMsg, setRebuildMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [rebuilding, setRebuilding] = useState(false)

  const runRebuild = async () => {
    if (rebuilding) return
    setRebuilding(true)
    setRebuildMsg(null)
    try {
      await adminRequest('POST', '/ratings/rebuild-all')
      setRebuildMsg({ kind: 'ok', text: t('admin.rebuildDone') })
    } catch (e) {
      setRebuildMsg({ kind: 'err', text: e instanceof Error ? e.message : 'Rebuild failed' })
    } finally {
      setRebuilding(false)
      setTimeout(() => setRebuildMsg(null), 5000)
    }
  }

  const { data: sessions, refetch: refetchSessions } = useListSessions()
  const { data: players, refetch: refetchPlayers } = useListPlayers()
  const { data: sources, refetch: refetchSources } = useRatingSources()
  const { data: seasons } = useRatingSeasons()
  const { data: tournaments, refetch: refetchTournaments } = useListTournaments()

  // Season aktif → default tanggal = tanggal mulai season aktif
  const openSeason = useMemo(() => (seasons ?? []).find((s) => s.open), [seasons])
  const [seasonDate, setSeasonDate] = useState<string | null>(null)
  const effectiveSeasonDate = seasonDate ?? openSeason?.start_date ?? new Date().toISOString().slice(0, 10)

  if (!isAdmin) {
    return (
      <div className="flex flex-col gap-3">
        <p className="text-amber-300/80 text-sm">Admin mode inactive.</p>
        <button onClick={() => navigate('/')} className="text-accent text-sm">Back to home</button>
      </div>
    )
  }

  const flash = (ok?: string, err?: string) => {
    setOkMsg(ok ?? null)
    setError(err ?? null)
    setTimeout(() => { setOkMsg(null); setError(null) }, 4000)
  }

  const run = async (fn: () => Promise<unknown>, okLabel: string, refresh?: () => void) => {
    setError(null)
    try {
      await fn()
      flash(okLabel)
      refresh?.()
    } catch (e) {
      flash(undefined, e instanceof Error ? e.message : 'Failed')
    }
  }

  const daySpan = (start: string, end: string | null, now: number) => {
    const s = new Date(start).getTime()
    const e = end ? new Date(end).getTime() : now
    return Math.max(1, Math.round((e - s) / 86400000))
  }

  const sessSlice = (sessions ?? []).slice(sessPage * PAGE, sessPage * PAGE + PAGE)
  const srcSlice = (sources ?? []).slice(srcPage * PAGE, srcPage * PAGE + PAGE)
  const filteredPlayers = (players ?? []).filter(
    (p) => !playerQuery || p.name.toLowerCase().includes(playerQuery.toLowerCase()),
  )
  const playerSlice = filteredPlayers.slice(playerPage * PAGE, playerPage * PAGE + PAGE)

  return (
    <div className="flex flex-col gap-5">
      {/* Banner pembeda */}
      <div className="flex items-center justify-between px-4 py-3 rounded-lg bg-amber-950/30 border border-amber-800/60">
        <div className="flex flex-col">
          <p className="text-sm font-bold text-amber-200">{t('admin.title')}</p>
          <p className="text-[10px] font-mono text-amber-300/60 uppercase tracking-wider">{t('admin.subtitle')}</p>
        </div>
        <button onClick={logout} className="text-xs font-mono text-fg-dim hover:text-red-400 transition-colors">{t('admin.logout')}</button>
      </div>

      {error && <p className="text-red-400 text-xs bg-red-950/30 border border-red-800/60 rounded-lg px-3 py-2">{error}</p>}
      {okMsg && <p className="text-emerald-400 text-xs bg-emerald-950/30 border border-emerald-800/60 rounded-lg px-3 py-2">{okMsg}</p>}

      {/* ── Session ── */}
      <section ref={sessionsRef} className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">{t('admin.sectionSession')}</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {sessSlice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">{t('admin.noSessions')}</p>}
          {sessSlice.map((s) => (
            <div key={s.id} className="flex flex-wrap items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{s.title || 'Untitled'}</span>
              <span className="text-[10px] font-mono text-fg-dim">{s.date}</span>
              <span className={`text-[10px] font-mono ${s.locked ? 'text-amber-300/70' : 'text-fg-dim'}`}>{s.locked ? t('admin.locked') : t('admin.draft')}</span>
              {s.locked && (
                <ActionButton tone="amber" onClick={() => run(() => adminRequest('POST', `/sessions/${s.id}/unlock`), t('admin.unlocked'))}>
                  Unlock
                </ActionButton>
              )}
              <ActionButton
                tone="red"
                onClick={() => {
                  if (window.confirm(en.admin.sessionDeleteConfirm(s.title || 'Untitled', s.date))) {
                    run(
                      () => adminRequest('POST', `/sessions/${s.id}/delete`),
                      t('admin.sessionDeleted'),
                      () => { refetchSessions(); refetchSources() },
                    )
                  }
                }}
              >
                Delete
              </ActionButton>
            </div>
          ))}
        </div>
        <Pager page={sessPage} total={(sessions ?? []).length} onPage={setSessPage} />
      </section>

      {/* ── Player ── */}
      <section ref={playersRef} className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">{t('admin.sectionPlayer')}</p>

        {/* Add player standalone (registry) */}
        <div className="flex flex-wrap gap-2 items-center bg-surface border border-border-subtle rounded-lg px-3 py-2">
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder={t('admin.newPlayerName')}
            className="flex-1 min-w-0 bg-transparent text-sm text-fg placeholder:text-fg-dim/60 focus:outline-none"
          />
          <select
            value={newTier}
            onChange={(e) => setNewTier(e.target.value)}
            className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs font-mono text-fg focus:outline-none"
            aria-label={t('admin.tierInduk')}
          >
            {TIERS.map((tier) => <option key={tier} value={tier}>Tier {tier}</option>)}
          </select>
          <button
            onClick={() => run(
              async () => {
                if (!newName.trim()) throw new Error(t('admin.nameRequired'))
                await adminRequest('POST', '/players', { name: newName.trim(), tier: newTier })
              },
              t('admin.playerAdded'),
            )}
            className="px-3 py-1.5 rounded-lg bg-accent text-slate-950 text-xs font-bold"
          >
            {t('admin.addPlayer')}
          </button>
        </div>

        {/* Filter by name (2.089+ players — pagination tanpa filter tidak berguna) */}
        <input
          value={playerQuery}
          onChange={(e) => { setPlayerQuery(e.target.value); setPlayerPage(0) }}
          placeholder="Filter players by name…"
          className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none"
        />

        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {playerSlice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No players match.</p>}
          {playerSlice.map((pl) => (
            <div key={pl.playerId ?? pl.name} className="px-3 py-2 flex flex-wrap items-center gap-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{pl.name}</span>
              {pl.tierInduk && (
                <span className="text-[10px] font-mono text-amber-300/80 border border-amber-800/50 rounded px-1.5 py-0.5">tier {pl.tierInduk}</span>
              )}
              <ActionButton onClick={() => {
                const newTier2 = window.prompt(en.admin.tierPrompt(pl.name), pl.tierInduk ?? 'C')
                if (newTier2 && TIERS.includes(newTier2.toUpperCase())) {
                  run(() => adminRequest('PATCH', `/players/${pl.playerId}/tier`, { tier: newTier2.toUpperCase() }), t('admin.tierChanged'))
                }
              }}>Tier</ActionButton>
              <ActionButton onClick={() => {
                const newName2 = window.prompt(en.admin.renamePrompt(pl.name), pl.name)
                if (newName2 && newName2.trim() && newName2.trim() !== pl.name) {
                  run(
                    () => adminRequest('PATCH', `/players/${pl.playerId}/name`, { name: newName2.trim() }),
                    t('admin.nameChanged'),
                    () => refetchPlayers(),
                  )
                }
              }}>Rename</ActionButton>
              <ActionButton tone="amber" onClick={() => {
                if (window.confirm(en.admin.rebaselineConfirm(pl.name))) {
                  run(() => adminRequest('POST', `/ratings/players/${pl.playerId}/rebaseline`), t('admin.rebaselined'))
                }
              }}>Rebaseline</ActionButton>
              <ActionButton tone="red" onClick={() => {
                if (window.confirm(en.admin.playerDeleteConfirm(pl.name))) {
                  run(() => adminRequest('DELETE', `/players/${pl.playerId}`), t('admin.playerDeleted'))
                }
              }}>Delete</ActionButton>
            </div>
          ))}
        </div>
        <Pager page={playerPage} total={filteredPlayers.length} onPage={setPlayerPage} />
      </section>

      {/* ── Rating ── */}
      <section ref={ratingsRef} className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">{t('admin.sectionRating')}</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {srcSlice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">{t('admin.noSources')}</p>}
          {srcSlice.map((src) => (
            <div key={src.source_id} className="flex flex-wrap items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-fg truncate font-mono text-xs">{src.source_id}</span>
              <span className="text-[10px] font-mono text-fg-dim">{src.event_count} ev</span>
              {src.source_kind.startsWith('tournament') && (
                <ActionButton
                  tone={src.finalized ? 'green' : 'neutral'}
                  onClick={() => run(() => adminRequest('POST', `/ratings/sources/${src.source_id}/finalize`, { finalized: !src.finalized }), src.finalized ? 'Un-finalized' : 'Finalized')}
                >
                  {src.finalized ? 'Finalized' : 'Finalize'}
                </ActionButton>
              )}
              <ActionButton onClick={() => run(() => adminRequest('POST', '/ratings/ingest-session', { sessionId: src.source_id }), 'Ingested')}>
                Ingest
              </ActionButton>
              <ActionButton tone="red" onClick={() => run(() => adminRequest('POST', '/ratings/revert-session', { sessionId: src.source_id }), 'Reverted')}>
                Revert
              </ActionButton>
            </div>
          ))}
        </div>
        <Pager page={srcPage} total={(sources ?? []).length} onPage={setSrcPage} />
        <div className="flex flex-col gap-1">
          <button
            onClick={runRebuild}
            disabled={rebuilding}
            className="py-2 rounded-lg border border-border-subtle text-sm text-fg-dim hover:text-fg disabled:opacity-40"
          >
            {rebuilding ? t('admin.rebuilding') : t('admin.rebuild')}
          </button>
          {rebuildMsg && (
            <p className={`text-[10px] font-mono ${rebuildMsg.kind === 'ok' ? 'text-emerald-400' : 'text-red-400'}`}>
              {rebuildMsg.text}
            </p>
          )}
          <p className="text-[10px] text-fg-dim">{t('admin.rebuildHelp')}</p>
        </div>
      </section>

      {/* ── Tournament ── */}
      <section ref={tournamentRef} className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">{t('admin.sectionTournament')}</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(tournaments ?? []).length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">{t('admin.noTournaments')}</p>}
          {(tournaments ?? []).map((t2) => (
            <div key={t2.id} className="flex flex-wrap items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{t2.name || 'Untitled Tournament'}</span>
              <span className="text-[10px] font-mono text-fg-dim">{t2.date}</span>
              <span className={`text-[10px] font-mono ${t2.format === 'team' ? 'text-accent' : 'text-fg-dim'}`}>{t2.format}</span>
              <ActionButton
                tone="red"
                onClick={() => {
                  if (window.confirm(en.admin.tournamentDeleteConfirm(t2.name || 'Untitled Tournament'))) {
                    run(
                      () => adminRequest('POST', `/tournaments/${t2.id}/delete`),
                      t('admin.tournamentDeleted'),
                      () => { refetchTournaments(); refetchSources() },
                    )
                  }
                }}
              >
                Delete
              </ActionButton>
            </div>
          ))}
        </div>
      </section>

      {/* ── Season ── */}
      <section ref={seasonRef} className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">{t('admin.sectionSeason')}</p>
        <div className="flex flex-wrap gap-2 items-end">
          <label className="flex flex-col gap-1 flex-1 min-w-40">
            <span className="text-[10px] font-mono text-fg-dim">{t('admin.seasonDateLabel')}</span>
            <input
              type="date"
              value={effectiveSeasonDate}
              onChange={(e) => setSeasonDate(e.target.value)}
              className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm font-mono text-fg scheme-dark focus:border-accent focus:outline-none"
            />
          </label>
          <button
            onClick={() => run(
              async () => { await adminRequest('POST', '/ratings/season', { startDate: effectiveSeasonDate }) },
              t('admin.seasonStarted'),
              () => { setSeasonDate(null) },
            )}
            className="px-3 py-2 rounded-lg bg-amber-700/60 text-amber-100 text-sm font-bold"
          >
            Close & Start New
          </button>
        </div>
        <p className="text-[10px] text-fg-dim">{t('admin.seasonHelp')}</p>

        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(seasons ?? []).map((s) => {
            const endLabel = s.open ? t('admin.active') : s.end_date ?? '—'
            return (
              <div key={s.id} className="flex flex-wrap items-center gap-x-3 gap-y-0.5 px-3 py-2">
                <span className={`text-sm font-semibold ${s.open ? 'text-accent' : 'text-fg'}`}>{s.name}</span>
                <span className={`text-[10px] font-mono ${s.open ? 'text-emerald-400' : 'text-fg-dim'}`}>{s.open ? `● ${t('admin.active')}` : 'closed'}</span>
                <span className="flex-1 min-w-36 text-[10px] font-mono text-fg-dim">
                  {s.start_date} → {endLabel} · {daySpan(s.start_date, s.end_date, nowMs)} {t('admin.days')}
                </span>
                <a href="/ratings" className="text-[10px] font-mono text-accent shrink-0">{t('admin.standings')} →</a>
              </div>
            )
          })}
        </div>
      </section>

    </div>
  )
}
