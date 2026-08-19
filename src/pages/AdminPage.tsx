// src/pages/AdminPage.tsx — halaman admin (ADMIN_MENU_PLAN §2.2).
import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAdmin } from '../context/AdminContext'
import { useListSessions, useListPlayers, useListTournaments } from '../queries'
import { useRatingSources, useRatingSeasons } from '../queries/ratings'
import { adminRequest } from '../queries/admin'

const TIERS = ['A', 'B', 'C', 'D']
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
        ← Prev
      </button>
      <span className="text-[10px] font-mono text-fg-dim">{page + 1} / {pages}</span>
      <button
        onClick={() => onPage(page + 1)}
        disabled={page >= pages - 1}
        className="text-xs font-mono text-fg-dim hover:text-fg disabled:opacity-30"
      >
        Next →
      </button>
    </div>
  )
}

export default function AdminPage() {
  const { isAdmin, logout } = useAdmin()
  const navigate = useNavigate()
  const [error, setError] = useState<string | null>(null)
  const [okMsg, setOkMsg] = useState<string | null>(null)

  // Pagination: sessions & sources (10/item)
  const [sessPage, setSessPage] = useState(0)
  const [srcPage, setSrcPage] = useState(0)
  // "now" stabil (sekali per mount) — daySpan jadi murni (lint: no impure in render)
  const [nowMs] = useState(() => Date.now())

  // Add player standalone (nama + tier induk — tanpa chain ke sesi)
  const [newName, setNewName] = useState('')
  const [newTier, setNewTier] = useState('C')

  // Feedback Rebuild All — inline dekat tombol (bukan flash global di atas)
  const [rebuildMsg, setRebuildMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [rebuilding, setRebuilding] = useState(false)

  const runRebuild = async () => {
    if (rebuilding) return
    setRebuilding(true)
    setRebuildMsg(null)
    try {
      await adminRequest('POST', '/ratings/rebuild-all')
      setRebuildMsg({ kind: 'ok', text: 'Rebuild done — semua rating dihitung ulang dari events' })
    } catch (e) {
      setRebuildMsg({ kind: 'err', text: e instanceof Error ? e.message : 'Rebuild failed' })
    } finally {
      setRebuilding(false)
      setTimeout(() => setRebuildMsg(null), 5000)
    }
  }

  const { data: sessions, refetch: refetchSessions } = useListSessions()
  const { data: players } = useListPlayers()
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

  return (
    <div className="flex flex-col gap-5">
      {/* Banner pembeda */}
      <div className="flex items-center justify-between px-4 py-3 rounded-lg bg-amber-950/30 border border-amber-800/60">
        <div className="flex flex-col">
          <p className="text-sm font-bold text-amber-200">Admin</p>
          <p className="text-[10px] font-mono text-amber-300/60 uppercase tracking-wider">operations</p>
        </div>
        <button onClick={logout} className="text-xs font-mono text-fg-dim hover:text-red-400 transition-colors">Logout</button>
      </div>

      {error && <p className="text-red-400 text-xs bg-red-950/30 border border-red-800/60 rounded-lg px-3 py-2">{error}</p>}
      {okMsg && <p className="text-emerald-400 text-xs bg-emerald-950/30 border border-emerald-800/60 rounded-lg px-3 py-2">{okMsg}</p>}

      {/* ── Session (SEMUA, paginasi 10) ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Session · unlock</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {sessSlice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No sessions.</p>}
          {sessSlice.map((s) => (
            <div key={s.id} className="flex items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{s.title || 'Untitled'}</span>
              <span className="text-[10px] font-mono text-fg-dim">{s.date}</span>
              <span className={`text-[10px] font-mono ${s.locked ? 'text-amber-300/70' : 'text-fg-dim'}`}>{s.locked ? 'locked' : 'draft'}</span>
              {s.locked && (
                <ActionButton tone="amber" onClick={() => run(() => adminRequest('POST', `/sessions/${s.id}/unlock`), 'Unlocked')}>
                  Unlock
                </ActionButton>
              )}
              <ActionButton
                tone="red"
                onClick={() => {
                  if (window.confirm(`Hapus sesi "${s.title || 'Untitled'}" (${s.date})?\n\nRating source ikut terhapus & semua rating di-rebuild.`)) {
                    run(
                      () => adminRequest('POST', `/sessions/${s.id}/delete`),
                      'Session dihapus + rating di-rebuild',
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

      {/* ── Rating ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Rating · ingest / revert</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {srcSlice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No sources.</p>}
          {srcSlice.map((src) => (
            <div key={src.source_id} className="flex items-center gap-2 px-3 py-2">
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
            {rebuilding ? 'Rebuilding…' : 'Rebuild All'}
          </button>
          {rebuildMsg && (
            <p className={`text-[10px] font-mono ${rebuildMsg.kind === 'ok' ? 'text-emerald-400' : 'text-red-400'}`}>
              {rebuildMsg.text}
            </p>
          )}
          <p className="text-[10px] text-fg-dim">
            Rebuild All = hitung ulang SEMUA rating dari events (dipakai setelah ubah config rating / koreksi; normalnya tidak perlu).
          </p>
        </div>
      </section>

      {/* ── Tournament ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Tournament · delete</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(tournaments ?? []).length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No tournaments.</p>}
          {(tournaments ?? []).map((t) => (
            <div key={t.id} className="flex items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{t.name || 'Untitled Tournament'}</span>
              <span className="text-[10px] font-mono text-fg-dim">{t.date}</span>
              <span className={`text-[10px] font-mono ${t.format === 'team' ? 'text-accent' : 'text-fg-dim'}`}>{t.format}</span>
              <ActionButton
                tone="red"
                onClick={() => {
                  if (window.confirm(`Hapus tournament "${t.name || 'Untitled Tournament'}"?\n\nRating source ikut terhapus & semua rating di-rebuild.`)) {
                    run(
                      () => adminRequest('POST', `/tournaments/${t.id}/delete`),
                      'Tournament dihapus + rating di-rebuild',
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
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Season</p>
        <div className="flex gap-2 items-end">
          <label className="flex flex-col gap-1 flex-1">
            <span className="text-[10px] font-mono text-fg-dim">Tanggal mulai season baru</span>
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
              'Season ditutup & musim baru dimulai',
              () => { setSeasonDate(null) },
            )}
            className="px-3 py-2 rounded-lg bg-amber-700/60 text-amber-100 text-sm font-bold"
          >
            Close & Start New
          </button>
        </div>
        <p className="text-[10px] text-fg-dim">Default = tanggal mulai season aktif. Menutup = arsip standings beku, semua pemain balik ke mid kelas.</p>

        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(seasons ?? []).map((s) => {
            const endLabel = s.open ? 'aktif' : s.end_date ?? '—'
            return (
              <div key={s.id} className="flex items-center gap-3 px-3 py-2">
                <span className={`text-sm font-semibold ${s.open ? 'text-accent' : 'text-fg'}`}>{s.name}</span>
                <span className={`text-[10px] font-mono ${s.open ? 'text-emerald-400' : 'text-fg-dim'}`}>{s.open ? '● aktif' : 'closed'}</span>
                <span className="flex-1 text-[10px] font-mono text-fg-dim truncate">
                  {s.start_date} → {endLabel} · {daySpan(s.start_date, s.end_date, nowMs)} hari
                </span>
                <a href="/ratings" className="text-[10px] font-mono text-accent shrink-0">standings →</a>
              </div>
            )
          })}
        </div>
      </section>

      {/* ── Player ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Player</p>

        {/* Add player standalone (registry) */}
        <div className="flex gap-2 items-center bg-surface border border-border-subtle rounded-lg px-3 py-2">
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="Nama player baru"
            className="flex-1 min-w-0 bg-transparent text-sm text-fg placeholder:text-fg-dim/60 focus:outline-none"
          />
          <select
            value={newTier}
            onChange={(e) => setNewTier(e.target.value)}
            className="bg-elevated border border-border rounded-lg px-2 py-1.5 text-xs font-mono text-fg focus:outline-none"
            aria-label="Tier induk"
          >
            {TIERS.map((t) => <option key={t} value={t}>Tier {t}</option>)}
          </select>
          <button
            onClick={() => run(
              async () => {
                if (!newName.trim()) throw new Error('Nama wajib diisi')
                await adminRequest('POST', '/players', { name: newName.trim(), tier: newTier })
              },
              'Player ditambahkan',
            )}
            className="px-3 py-1.5 rounded-lg bg-accent text-slate-950 text-xs font-bold"
          >
            Add
          </button>
        </div>

        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(players ?? []).map((pl) => (
            <div key={pl.playerId ?? pl.name} className="px-3 py-2 flex items-center gap-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{pl.name}</span>
              {pl.tierInduk && (
                <span className="text-[10px] font-mono text-amber-300/80 border border-amber-800/50 rounded px-1.5 py-0.5">tier {pl.tierInduk}</span>
              )}
              <ActionButton onClick={() => {
                const newTier2 = window.prompt(`Tier induk (A/B/C/D) untuk ${pl.name}:`, pl.tierInduk ?? 'C')
                if (newTier2 && TIERS.includes(newTier2.toUpperCase())) {
                  run(() => adminRequest('PATCH', `/players/${pl.playerId}/tier`, { tier: newTier2.toUpperCase() }), 'Tier diubah + recalculate')
                }
              }}>Tier</ActionButton>
              <ActionButton tone="red" onClick={() => {
                if (window.confirm(`Hapus player "${pl.name}"? (riwayat sesi tetap, rating ikut terhapus)`)) {
                  run(() => adminRequest('DELETE', `/players/${pl.playerId}`), 'Player dihapus')
                }
              }}>Hapus</ActionButton>
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}
