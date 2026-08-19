// src/pages/AdminPage.tsx — halaman admin (ADMIN_MENU_PLAN §2.2).
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAdmin } from '../context/AdminContext'
import { useListSessions, useListPlayers } from '../queries'
import { adminRequest } from '../queries/admin'

const TIERS = ['A', 'B', 'C', 'D']
const CLASSES = ['D-', 'D', 'D+', 'C-', 'C', 'C+', 'B-', 'B', 'B+', 'A-', 'A', 'A+']
import { useRatingSources, useRatingSeasons } from '../queries/ratings'

export default function AdminPage() {
  const { isAdmin, logout } = useAdmin()
  const navigate = useNavigate()
  const [error, setError] = useState<string | null>(null)
  const [okMsg, setOkMsg] = useState<string | null>(null)
  const [seasonDate, setSeasonDate] = useState(() => new Date().toISOString().slice(0, 10))

  const { data: sessions } = useListSessions()
  const { data: players } = useListPlayers()
  const { data: sources } = useRatingSources()
  const { data: seasons } = useRatingSeasons()

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

  const run = async (fn: () => Promise<unknown>, okLabel: string) => {
    setError(null)
    try {
      await fn()
      flash(okLabel)
    } catch (e) {
      flash(undefined, e instanceof Error ? e.message : 'Failed')
    }
  }

  return (
    <div className="flex flex-col gap-4">
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

      {/* ── Session ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Session</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(sessions ?? []).slice(0, 8).map((s) => (
            <div key={s.id} className="flex items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{s.title || 'Untitled'}</span>
              <span className="text-[10px] font-mono text-fg-dim">{s.date}</span>
              {s.locked && (
                <button
                  onClick={() => run(() => adminRequest('POST', `/sessions/${s.id}/unlock`), `Unlocked ${s.title || s.id}`)}
                  className="text-[10px] font-mono px-2 py-1 rounded border border-amber-700/50 text-amber-300 hover:bg-amber-900/40"
                >
                  Unlock
                </button>
              )}
            </div>
          ))}
        </div>
      </section>

      {/* ── Rating ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Rating</p>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(sources ?? []).map((src) => (
            <div key={src.source_id} className="flex items-center gap-2 px-3 py-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate font-mono text-xs">{src.source_id}</span>
              <span className="text-[10px] font-mono text-fg-dim">{src.event_count} ev</span>
              {src.source_kind.startsWith('tournament') && (
                <button
                  onClick={() => run(() => adminRequest('POST', `/ratings/sources/${src.source_id}/finalize`, { finalized: !src.finalized }), src.finalized ? 'Un-finalized' : 'Finalized')}
                  className={`text-[10px] font-mono px-2 py-1 rounded border ${src.finalized ? 'border-emerald-700/60 text-emerald-400' : 'border-border text-fg-dim hover:text-fg'}`}
                >
                  {src.finalized ? 'Finalized' : 'Finalize'}
                </button>
              )}
              <button
                onClick={() => run(() => adminRequest('POST', '/ratings/ingest-session', { sessionId: src.source_id }), 'Ingested')}
                className="text-[10px] font-mono px-2 py-1 rounded border border-border text-fg-dim hover:text-fg"
              >
                Ingest
              </button>
              <button
                onClick={() => run(() => adminRequest('POST', '/ratings/revert-session', { sessionId: src.source_id }), 'Reverted')}
                className="text-[10px] font-mono px-2 py-1 rounded border border-red-800/50 text-red-400 hover:bg-red-950/40"
              >
                Revert
              </button>
            </div>
          ))}
        </div>
        <button
          onClick={() => run(() => adminRequest('POST', '/ratings/rebuild-all'), 'Rebuild done')}
          className="py-2 rounded-lg border border-border-subtle text-sm text-fg-dim hover:text-fg"
        >
          Rebuild All
        </button>
      </section>

      {/* ── Season ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Season</p>
        <div className="flex gap-2 items-center">
          <input
            type="date"
            value={seasonDate}
            onChange={(e) => setSeasonDate(e.target.value)}
            className="bg-elevated border border-border rounded-lg px-3 py-2 text-sm font-mono text-fg scheme-dark flex-1"
          />
          <button
            onClick={() => run(
              async () => {
                const r = await adminRequest('POST', '/ratings/season', { startDate: seasonDate })
                return r
              },
              'Season closed & new started',
            )}
            className="px-3 py-2 rounded-lg bg-amber-700/60 text-amber-100 text-sm font-bold"
          >
            Close & Start New
          </button>
        </div>
        <p className="text-[10px] font-mono text-fg-dim">{(seasons ?? []).map((s) => `${s.name}${s.open ? ' (open)' : ''}`).join(' · ')}</p>
        <a href="/ratings" className="text-xs text-accent">Lihat arsip musim (standings beku) →</a>
      </section>

      {/* ── Player ── */}
      <section className="flex flex-col gap-2">
        <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Player</p>
        <button onClick={() => navigate('/session/players')} className="py-2 rounded-lg border border-border-subtle text-sm text-fg-dim hover:text-fg">
          Add player (ke sesi) →
        </button>
        <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
          {(players ?? []).map((pl) => (
            <div key={pl.playerId ?? pl.name} className="px-3 py-2 flex items-center gap-2">
              <span className="flex-1 min-w-0 text-sm text-fg truncate">{pl.name}</span>
              {pl.tierInduk && (
                <span className="text-[10px] font-mono text-amber-300/80 border border-amber-800/50 rounded px-1.5 py-0.5">tier {pl.tierInduk}</span>
              )}
              <button
                onClick={() => {
                  const newTier = window.prompt(`Tier induk (A/B/C/D) untuk ${pl.name}:`, pl.tierInduk ?? 'C')
                  if (newTier && TIERS.includes(newTier.toUpperCase())) {
                    run(() => adminRequest('PATCH', `/players/${pl.playerId}/tier`, { tier: newTier.toUpperCase() }), 'Tier diubah + recalculate')
                  }
                }}
                className="text-[10px] font-mono px-2 py-1 rounded border border-border text-fg-dim hover:text-fg"
              >
                Tier
              </button>
              <button
                onClick={() => {
                  const cls = window.prompt(`Class rating (D-..A+) untuk ${pl.name}:`, 'C')
                  if (cls && CLASSES.includes(cls)) {
                    run(() => adminRequest('PATCH', `/ratings/players/${pl.playerId}/class`, { class: cls }), 'Class diubah')
                  }
                }}
                className="text-[10px] font-mono px-2 py-1 rounded border border-border text-fg-dim hover:text-fg"
              >
                Class
              </button>
              <button
                onClick={() => {
                  if (window.confirm(`Hapus player "${pl.name}"? (riwayat sesi tetap, rating ikut terhapus)`)) {
                    run(() => adminRequest('DELETE', `/players/${pl.playerId}`), 'Player dihapus')
                  }
                }}
                className="text-[10px] font-mono px-2 py-1 rounded border border-red-800/50 text-red-400 hover:bg-red-950/40"
              >
                Hapus
              </button>
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}
